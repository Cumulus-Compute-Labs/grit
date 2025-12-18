#!/bin/bash
set -eo pipefail

# ============================================================================
# Checkpoint Node Setup Script
# Sets up the first node (k3s server) for GPU checkpoint/restore
# ============================================================================
#
# Prerequisites:
# - Ubuntu 22.04
# - NVIDIA driver 550+ installed
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
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root (use sudo)"
   exit 1
fi

log_info "Setting up Checkpoint Node (k3s server)..."

# ============================================================================
# Step 0: Install NVIDIA Driver and base packages
# ============================================================================
log_info "Step 0: Checking NVIDIA driver and installing base packages..."

apt-get update -qq
apt-get install -y git make build-essential wget curl criu

if ! nvidia-smi &> /dev/null; then
    log_info "Installing NVIDIA driver 550..."
    apt-get install -y nvidia-driver-550
    log_success "NVIDIA driver installed"
    echo ""
    echo -e "${YELLOW}[IMPORTANT]${NC} Reboot required for NVIDIA driver!"
    echo -e "${YELLOW}[IMPORTANT]${NC} Run: sudo reboot"
    echo -e "${YELLOW}[IMPORTANT]${NC} Then re-run this script after reboot"
    echo ""
    exit 0
else
    log_success "NVIDIA driver already installed: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
fi

log_success "CRIU installed: $(criu --version | head -1)"

# ============================================================================
# Step 1: Install Docker (for building GRIT images)
# ============================================================================
log_info "Step 1: Installing Docker for building GRIT images..."

if ! command -v docker &> /dev/null; then
    apt-get install -y docker.io docker-buildx
    systemctl enable docker
    systemctl start docker
    log_success "Docker installed"
else
    log_success "Docker already installed"
fi

# ============================================================================
# Step 2: Install Go and build GRIT shim
# ============================================================================
log_info "Step 2: Building GRIT shim from source..."

# Install Go 1.23+ (apt version is too old)
if ! /usr/local/go/bin/go version 2>/dev/null | grep -q "go1.23"; then
    log_info "Installing Go 1.23..."
    wget -q https://go.dev/dl/go1.23.4.linux-amd64.tar.gz -O /tmp/go.tar.gz
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz
fi
export PATH=/usr/local/go/bin:$PATH

log_info "Go version: $(/usr/local/go/bin/go version)"

GRIT_DIR="/tmp/grit"
rm -rf "$GRIT_DIR"
git clone https://github.com/Cumulus-Compute-Labs/grit.git "$GRIT_DIR"
cd "$GRIT_DIR"
PATH=/usr/local/go/bin:$PATH make bin/containerd-shim-grit-v1
cp _output/containerd-shim-grit-v1 /usr/local/bin/
chmod +x /usr/local/bin/containerd-shim-grit-v1
log_success "GRIT shim installed"

# ============================================================================
# Step 3: Install NVIDIA Container Toolkit
# ============================================================================
log_info "Step 3: Installing NVIDIA Container Toolkit..."

if ! command -v nvidia-ctk &> /dev/null; then
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null || true
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update -qq
    apt-get install -y nvidia-container-toolkit
    log_success "NVIDIA Container Toolkit installed"
else
    log_success "NVIDIA Container Toolkit already installed"
fi

# ============================================================================
# Step 4: Install and configure containerd 2.x
# ============================================================================
log_info "Step 4: Installing/configuring containerd 2.x..."

# Install containerd if not present or upgrade to 2.x
CONTAINERD_VER=$(containerd --version 2>/dev/null | grep -oP 'v?\d+\.\d+\.\d+' | head -1 || echo "0")
if [[ ! "$CONTAINERD_VER" =~ ^v?2\. ]]; then
    log_info "Installing containerd 2.0.4..."
    systemctl stop containerd 2>/dev/null || true
    wget -q https://github.com/containerd/containerd/releases/download/v2.0.4/containerd-2.0.4-linux-amd64.tar.gz -O /tmp/containerd.tar.gz
    tar -xzf /tmp/containerd.tar.gz -C /usr
    rm /tmp/containerd.tar.gz
fi

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
        [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v2"

        [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.grit]
          runtime_type = "io.containerd.grit.v1"
          container_annotations = ["grit.dev/*"]
          pod_annotations = ["grit.dev/*"]
          [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.grit.options]
            ConfigPath = "/etc/containerd/grit.toml"

        [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.nvidia]
          runtime_type = "io.containerd.runc.v2"
          [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.nvidia.options]
            BinaryName = "/usr/bin/nvidia-container-runtime"
CONTAINERD_CONFIG

# GRIT must use nvidia-container-runtime for GPU passthrough
cat > /etc/containerd/grit.toml << 'GRIT_CONFIG'
BinaryName = "/usr/bin/nvidia-container-runtime"
Root = "/run/containerd/runc"
SystemdCgroup = false
GRIT_CONFIG

# Generate CDI specs for NVIDIA
if nvidia-smi &> /dev/null; then
    nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
    log_success "CDI specs generated"
fi

# Create systemd unit if needed
if [ ! -f /lib/systemd/system/containerd.service ]; then
    cat > /lib/systemd/system/containerd.service << 'SYSTEMD'
[Unit]
Description=containerd container runtime
After=network.target

[Service]
ExecStart=/usr/bin/containerd
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SYSTEMD
fi

systemctl daemon-reload
systemctl enable containerd
systemctl restart containerd
sleep 5
log_success "Containerd 2.x configured: $(containerd --version)"

# ============================================================================
# Step 5: Install k3s server
# ============================================================================
log_info "Step 5: Installing k3s server..."

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
    --container-runtime-endpoint unix:///run/containerd/containerd.sock \
    --disable=traefik \
    --write-kubeconfig-mode=644" sh -

# Wait for k3s
for i in {1..60}; do
    kubectl get nodes &> /dev/null && break
    sleep 2
done
log_success "k3s server running"

# Fix CNI symlinks
mkdir -p /opt/cni/bin
ln -sf /var/lib/rancher/k3s/data/*/bin/* /opt/cni/bin/ 2>/dev/null || true

# ============================================================================
# Step 6: Install Helm and GRIT Manager
# ============================================================================
log_info "Step 6: Installing Helm and GRIT Manager..."

# Install helm
if ! command -v helm &> /dev/null; then
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
log_success "Helm installed"

# Fix runtimeSocket path in values.yaml (use /run/containerd not /run/k3s/containerd)
sed -i 's|/run/k3s/containerd/containerd.sock|/run/containerd/containerd.sock|g' /tmp/grit/charts/grit-manager/values.yaml

# Build and import GRIT images
log_info "Building GRIT Manager image..."
cd /tmp/grit
docker buildx build -t ghcr.io/cumulus-compute-labs/grit-manager:dev -f docker/grit-manager/Dockerfile .
docker save ghcr.io/cumulus-compute-labs/grit-manager:dev | ctr -n k8s.io images import -

log_info "Building GRIT Agent image..."
docker buildx build -t ghcr.io/cumulus-compute-labs/grit-agent:dev -f docker/grit-agent/Dockerfile .
docker save ghcr.io/cumulus-compute-labs/grit-agent:dev | ctr -n k8s.io images import -

log_success "GRIT images built and imported"

# Install GRIT CRDs and manager via helm
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
helm upgrade --install grit-manager /tmp/grit/charts/grit-manager -n kube-system --wait --timeout=120s

log_success "GRIT Manager deployed"

# ============================================================================
# Step 7: Create RuntimeClasses and NVIDIA device plugin
# ============================================================================
log_info "Step 7: Setting up RuntimeClasses and NVIDIA device plugin..."

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
# Step 8: Set up storage (with proper binding)
# ============================================================================
log_info "Step 8: Setting up storage..."

mkdir -p /mnt/checkpoint /mnt/grit-agent
chmod 755 /mnt/checkpoint /mnt/grit-agent

# Use storageClassName: "" with explicit volumeName for proper binding
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
  storageClassName: ""
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
  storageClassName: ""
  volumeName: checkpoint-pv
  resources:
    requests:
      storage: 10Gi
EOF

log_success "Storage configured"

# Wait for everything to be ready
log_info "Waiting for all pods to be ready..."
sleep 30

# ============================================================================
# Summary
# ============================================================================
echo ""
log_success "==========================================="
log_success "Checkpoint Node Setup Complete!"
log_success "==========================================="
echo ""
log_info "Verification:"
kubectl get nodes
echo ""
kubectl get pods -n kube-system | grep -E "grit|nvidia"
echo ""
kubectl get pvc
echo ""
log_info "Node token for restore node:"
cat /var/lib/rancher/k3s/server/node-token
echo ""
log_info "Server URL: https://$(hostname -I | awk '{print $1}'):6443"
echo ""
log_warn "NOTE: GPU checkpoint/restore requires CRIU 4.0+ and cuda-checkpoint for full GPU support"
log_warn "Current CRIU version: $(criu --version | head -1)"
echo ""
