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
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

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
log_info "Step 2: Building GRIT shim..."

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

# Install containerd 2.x
CONTAINERD_VER=$(containerd --version 2>/dev/null | grep -oP 'v?\d+\.\d+\.\d+' | head -1 || echo "0")
if [[ ! "$CONTAINERD_VER" =~ ^v?2\. ]]; then
    log_info "Installing containerd 2.0.4..."
    systemctl stop containerd 2>/dev/null || true
    wget -q https://github.com/containerd/containerd/releases/download/v2.0.4/containerd-2.0.4-linux-amd64.tar.gz -O /tmp/containerd.tar.gz
    tar -xzf /tmp/containerd.tar.gz -C /usr
    rm /tmp/containerd.tar.gz
fi

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
# Step 5: Build and import GRIT agent image
# ============================================================================
log_info "Step 5: Building GRIT Agent image..."

cd /tmp/grit
docker buildx build -t ghcr.io/cumulus-compute-labs/grit-agent:dev -f docker/grit-agent/Dockerfile .
docker save ghcr.io/cumulus-compute-labs/grit-agent:dev | ctr -n k8s.io images import -

log_success "GRIT Agent image built and imported"

# ============================================================================
# Step 6: Join k3s cluster
# ============================================================================
log_info "Step 6: Joining k3s cluster..."

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="agent \
    --server $SERVER_URL \
    --token $NODE_TOKEN \
    --container-runtime-endpoint unix:///run/containerd/containerd.sock" sh -

for i in {1..60}; do
    systemctl is-active --quiet k3s-agent && break
    sleep 2
done
log_success "k3s agent running"

# Fix CNI symlinks
mkdir -p /opt/cni/bin
ln -sf /var/lib/rancher/k3s/data/*/bin/* /opt/cni/bin/ 2>/dev/null || true

# ============================================================================
# Step 7: Set up storage
# ============================================================================
log_info "Step 7: Setting up storage..."

mkdir -p /mnt/checkpoint /mnt/grit-agent
chmod 755 /mnt/checkpoint /mnt/grit-agent

log_success "Storage configured"

echo ""
log_success "==========================================="
log_success "Restore Node Setup Complete!"
log_success "==========================================="
echo ""
log_info "Verify on checkpoint node: kubectl get nodes -o wide"
echo ""
log_warn "NOTE: GPU checkpoint/restore requires CRIU 4.0+ and cuda-checkpoint for full GPU support"
log_warn "Current CRIU version: $(criu --version | head -1)"
echo ""
