#!/bin/bash
set -eo pipefail

# ============================================================================
# Restore Node Setup Script
# Sets up the second node (k3s agent) for GPU checkpoint/restore
# ============================================================================
#
# Usage: sudo ./setup-restore-node.sh --server-url <URL> --token <TOKEN>
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

SERVER_URL=""
NODE_TOKEN=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --server-url) SERVER_URL="$2"; shift 2 ;;
        --token) NODE_TOKEN="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 --server-url <URL> --token <TOKEN>"
            exit 0 ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root (use sudo)"
   exit 1
fi

[ -z "$SERVER_URL" ] && { log_error "--server-url required"; exit 1; }
[ -z "$NODE_TOKEN" ] && { log_error "--token required"; exit 1; }

log_info "Setting up Restore Node (k3s agent)..."
log_info "Server URL: $SERVER_URL"

# ============================================================================
# Step 1: Build and install GRIT shim
# ============================================================================
log_info "Step 1: Building GRIT shim..."

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
systemctl stop k3s-agent 2>/dev/null || true
sleep 2

# Remove old binary if it exists
rm -f /usr/local/bin/containerd-shim-grit-v1 2>/dev/null || true

cp _output/containerd-shim-grit-v1 /usr/local/bin/
chmod +x /usr/local/bin/containerd-shim-grit-v1
log_success "GRIT shim installed"

# ============================================================================
# Step 2: Configure containerd (same as checkpoint node)
# ============================================================================
log_info "Step 2: Configuring containerd..."

mkdir -p /etc/containerd /etc/cdi

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

nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

systemctl enable containerd
systemctl restart containerd
sleep 5
log_success "Containerd configured"

# ============================================================================
# Step 3: Join k3s cluster
# ============================================================================
log_info "Step 3: Joining k3s cluster..."

# Retry k3s install up to 3 times (GitHub can be flaky)
for attempt in 1 2 3; do
    log_info "k3s install attempt $attempt..."
    if curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="agent \
        --server $SERVER_URL \
        --token $NODE_TOKEN \
        --container-runtime-endpoint unix:///run/containerd/containerd.sock" sh -; then
        break
    fi
    log_info "Attempt $attempt failed, waiting 10s before retry..."
    sleep 10
done

for i in {1..60}; do
    systemctl is-active --quiet k3s-agent && break
    sleep 2
done
log_success "k3s agent running"

# ============================================================================
# Step 4: Set up storage
# ============================================================================
log_info "Step 4: Setting up storage..."

mkdir -p /mnt/checkpoint /mnt/grit-agent
chmod 755 /mnt/checkpoint /mnt/grit-agent

log_success "Storage configured"

# ============================================================================
# Step 5: Ensure CRIU and NVIDIA configs for GPU checkpoint
# ============================================================================
log_info "Step 5: Ensuring CRIU and NVIDIA configs for GPU checkpoint..."

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

echo ""
log_success "==========================================="
log_success "Restore Node Setup Complete!"
log_success "==========================================="
echo ""
log_info "Verify on checkpoint node: kubectl get nodes -o wide"
echo ""
