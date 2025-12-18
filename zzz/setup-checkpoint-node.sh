#!/bin/bash
set -eo pipefail

# ============================================================================
# Checkpoint Node Setup Script
# Sets up the first node (k3s server) for GPU checkpoint/restore
# ============================================================================
#
# Prerequisites:
# - Ubuntu 22.04
# - NVIDIA driver 580+ installed
# - CRIU 4.0+ and cuda-checkpoint installed
# - NVIDIA Container Toolkit installed
#
# Usage: sudo ./setup-checkpoint-node.sh
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root (use sudo)"
   exit 1
fi

log_info "Setting up Checkpoint Node (k3s server)..."

# ============================================================================
# Step 1: Build and install GRIT shim
# ============================================================================
log_info "Step 1: Building GRIT shim from source..."

# Need Go 1.23+ for the GRIT project
GO_VERSION="1.23.4"
if ! go version 2>/dev/null | grep -q "go1.23"; then
    log_info "Installing Go $GO_VERSION..."
    apt-get update -qq
    apt-get install -y git
    cd /tmp
    wget -q https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz
    rm -rf /usr/local/go
    tar -C /usr/local -xzf go${GO_VERSION}.linux-amd64.tar.gz
    rm go${GO_VERSION}.linux-amd64.tar.gz
    export PATH=/usr/local/go/bin:$PATH
    echo 'export PATH=/usr/local/go/bin:$PATH' >> /etc/bash.bashrc
fi
export PATH=/usr/local/go/bin:$PATH

GRIT_DIR="/tmp/grit-build"
rm -rf "$GRIT_DIR"
git clone https://github.com/kaito-project/grit.git "$GRIT_DIR"
cd "$GRIT_DIR"
make bin/containerd-shim-grit-v1

# Stop containerd if running (binary might be in use)
systemctl stop containerd 2>/dev/null || true
systemctl stop k3s 2>/dev/null || true
sleep 2

# Remove old binary if it exists
rm -f /usr/local/bin/containerd-shim-grit-v1 2>/dev/null || true

cp _output/containerd-shim-grit-v1 /usr/local/bin/
chmod +x /usr/local/bin/containerd-shim-grit-v1
log_success "GRIT shim installed"

# ============================================================================
# Step 2: Configure containerd with GRIT runtime
# ============================================================================
log_info "Step 2: Configuring containerd..."

mkdir -p /etc/containerd /etc/cdi

# Backup existing config
[ -f /etc/containerd/config.toml ] && cp /etc/containerd/config.toml /etc/containerd/config.toml.backup

cat > /etc/containerd/config.toml << 'CONTAINERD_CONFIG'
version = 3

[plugins]
  [plugins."io.containerd.cri.v1.images"]
    snapshotter = "overlayfs"
    [plugins."io.containerd.cri.v1.images".pinned_images]
      sandbox = "registry.k8s.io/pause:3.10"

  [plugins."io.containerd.cri.v1.runtime"]
    cdi_spec_dirs = ["/etc/cdi", "/var/run/cdi"]
    enable_cdi = true

    [plugins."io.containerd.cri.v1.runtime".containerd]
      default_runtime_name = "runc"

      [plugins."io.containerd.cri.v1.runtime".containerd.runtimes]
        [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.grit]
          runtime_type = "io.containerd.grit.v1"
          container_annotations = ["grit.dev/*"]
          pod_annotations = ["grit.dev/*"]
          [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.grit.options]
            ConfigPath = "/etc/containerd/grit.toml"
            TypeUrl = "containerd.runc.v1.Options"

        [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.nvidia]
          runtime_type = "io.containerd.runc.v2"
          [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.nvidia.options]
            BinaryName = "/usr/bin/nvidia-container-runtime"

        [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v2"
CONTAINERD_CONFIG

# GRIT must use nvidia-container-runtime for GPU passthrough
cat > /etc/containerd/grit.toml << 'GRIT_CONFIG'
BinaryName = "/usr/bin/nvidia-container-runtime"
Root = "/run/containerd/runc"
SystemdCgroup = false
GRIT_CONFIG

# Generate CDI specs for NVIDIA
nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

systemctl enable containerd
systemctl restart containerd
sleep 5
log_success "Containerd configured"

# ============================================================================
# Step 3: Install k3s server
# ============================================================================
log_info "Step 3: Installing k3s server..."

# Retry k3s install up to 3 times (GitHub can be flaky)
for attempt in 1 2 3; do
    log_info "k3s install attempt $attempt..."
    if curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
        --container-runtime-endpoint unix:///run/containerd/containerd.sock \
        --disable=traefik \
        --write-kubeconfig-mode=644" sh -; then
        break
    fi
    log_info "Attempt $attempt failed, waiting 10s before retry..."
    sleep 10
done

# Force start/restart k3s
systemctl daemon-reload
systemctl restart k3s
sleep 5

# Wait for k3s
log_info "Waiting for k3s to be ready..."
for i in {1..60}; do
    kubectl get nodes &> /dev/null && break
    sleep 2
done
log_success "k3s server running"

# ============================================================================
# Step 4: Create RuntimeClasses and NVIDIA device plugin
# ============================================================================
log_info "Step 4: Setting up RuntimeClasses and NVIDIA device plugin..."

kubectl apply -f - <<EOF
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: grit
handler: grit
---
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-device-plugin-daemonset
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: nvidia-device-plugin-ds
  template:
    metadata:
      labels:
        name: nvidia-device-plugin-ds
    spec:
      runtimeClassName: nvidia
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      priorityClassName: system-node-critical
      containers:
      - image: nvcr.io/nvidia/k8s-device-plugin:v0.14.5
        name: nvidia-device-plugin-ctr
        args: ["--fail-on-init-error=false"]
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
        volumeMounts:
        - name: device-plugin
          mountPath: /var/lib/kubelet/device-plugins
      volumes:
      - name: device-plugin
        hostPath:
          path: /var/lib/kubelet/device-plugins
EOF

log_success "RuntimeClasses and NVIDIA device plugin created"

# ============================================================================
# Step 5: Set up storage
# ============================================================================
log_info "Step 5: Setting up storage..."

mkdir -p /mnt/checkpoint /mnt/grit-agent
chmod 755 /mnt/checkpoint /mnt/grit-agent

kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: checkpoint-pv
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  hostPath:
    path: /mnt/checkpoint
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ckpt-store
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 10Gi
EOF

log_success "Storage configured"

# ============================================================================
# Step 6: Ensure CRIU and NVIDIA configs for GPU checkpoint
# ============================================================================
log_info "Step 6: Ensuring CRIU and NVIDIA configs for GPU checkpoint..."

# Create CRIU config with external mount support (fixes nvidia mount issues)
mkdir -p /etc/criu
cat > /etc/criu/default.conf << 'EOF'
# CRIU configuration for GPU container checkpoint
# Handles nvidia-container-runtime shared mounts
external mnt[]:sm
EOF
log_info "CRIU config created at /etc/criu/default.conf"

# Configure nvidia-container-runtime for legacy mode (fixes seccomp issues)
mkdir -p /etc/nvidia-container-runtime
cat > /etc/nvidia-container-runtime/config.toml << 'EOF'
[nvidia-container-runtime]
mode = "legacy"
EOF
log_info "nvidia-container-runtime configured for legacy mode"

# Restart containerd to apply nvidia config
systemctl restart containerd
sleep 3

log_success "GPU checkpoint configs applied"

# ============================================================================
# Summary
# ============================================================================
echo ""
log_success "==========================================="
log_success "Checkpoint Node Setup Complete!"
log_success "==========================================="
echo ""
log_info "Node token for restore node:"
cat /var/lib/rancher/k3s/server/node-token
echo ""
log_info "Server URL: https://$(hostname -I | awk '{print $1}'):6443"
echo ""
