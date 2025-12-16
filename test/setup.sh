#!/bin/bash
# =============================================================================
# GRIT GPU Worker Node Setup Script
# Ubuntu 22.04 - Production Ready
# =============================================================================
#
# This script sets up a complete GRIT GPU worker node with:
# - NVIDIA Driver 580+
# - CUDA Toolkit 12.3
# - CRIU 4.0+ (built from source)
# - cuda-checkpoint (from NVIDIA)
# - NVIDIA Container Toolkit
# - K3s with NVIDIA + GRIT runtimes
# - NFS for checkpoint storage (server or client)
# - Helm + GRIT installed via Helm chart
# - PyTorch with CUDA 12.x
#
# Usage:
#   sudo ./setup-grit.sh                          # Single node (local storage)
#   sudo ./setup-grit.sh --nfs-server             # Multi-node: NFS server
#   sudo ./setup-grit.sh --nfs-client <SERVER_IP> # Multi-node: NFS client
#
# =============================================================================

set -eo pipefail

# Ensure PATH is set correctly
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}

# =============================================================================
# Parse Arguments
# =============================================================================
NFS_MODE=""
NFS_SERVER_IP=""
GRIT_REPO="https://github.com/Cumulus-Compute-Labs/grit.git"
GRIT_BRANCH="main"

while [[ $# -gt 0 ]]; do
    case $1 in
        --nfs-server) NFS_MODE="server"; shift ;;
        --nfs-client) NFS_MODE="client"; NFS_SERVER_IP="$2"; shift 2 ;;
        --grit-repo) GRIT_REPO="$2"; shift 2 ;;
        --grit-branch) GRIT_BRANCH="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; echo "Usage: $0 [--nfs-server|--nfs-client <IP>]"; exit 1 ;;
    esac
done

# =============================================================================
# Colors and Logging
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check root
[[ $EUID -ne 0 ]] && { log_error "This script must be run as root (use sudo)"; exit 1; }

# Check Ubuntu version
grep -q "Ubuntu 22.04" /etc/os-release 2>/dev/null || log_warn "This script is designed for Ubuntu 22.04"

# =============================================================================
# STEP 1: Clean Conflicting NVIDIA Packages
# =============================================================================
log_info "Step 1: Cleaning up conflicting NVIDIA packages..."

modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>/dev/null || true
systemctl stop nvidia-persistenced 2>/dev/null || true

# Wait for unattended-upgrade
for i in {1..30}; do pgrep -f unattended-upgrade > /dev/null 2>&1 && sleep 2 || break; done

rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock /var/lib/apt/lists/lock
dpkg --configure -a || true
apt-get update -qq || true

# Purge NVIDIA packages
apt-get purge -y \
    '^nvidia-driver.*' '^nvidia-dkms.*' '^nvidia-utils.*' '^nvidia-compute.*' \
    '^nvidia-headless.*' '^libnvidia-.*' '^cuda-toolkit.*' \
    nvidia-container-toolkit nvidia-container-runtime 2>/dev/null || true

# Unhold and force remove
for pkg in $(dpkg -l | grep -E '^hi' | grep -E 'nvidia|libnvidia' | awk '{print $2}'); do
    apt-mark unhold "$pkg" 2>/dev/null || true
    dpkg --purge --force-remove-reinstreq --force-depends "$pkg" 2>/dev/null || true
done

dpkg -l | grep -i nvidia | awk '{print $2}' | xargs -r apt-get purge -y 2>/dev/null || true
dpkg -l | grep -i cuda | awk '{print $2}' | xargs -r apt-get purge -y 2>/dev/null || true

apt-get autoremove -y && apt-get autoclean -y
find /lib/modules -name "nvidia*.ko" -delete 2>/dev/null || true
rm -rf /usr/lib/x86_64-linux-gnu/libnvidia* /usr/lib/x86_64-linux-gnu/libcuda* 2>/dev/null || true
depmod -a
apt-get update -qq

log_success "Step 1 complete: Conflicting packages removed"

# =============================================================================
# STEP 2: Install NVIDIA Driver 580+
# =============================================================================
log_info "Step 2: Installing NVIDIA Driver 580+..."

apt-get install -y software-properties-common apt-transport-https ca-certificates gnupg wget build-essential dkms
add-apt-repository -y ppa:graphics-drivers/ppa
apt-get update -qq

apt-get install -y nvidia-driver-580 nvidia-dkms-580 || {
    log_warn "Direct installation failed, resolving dependencies..."
    apt-get remove -y libnvidia-cfg1-575 libnvidia-cfg1-580 2>/dev/null || true
    apt-get install -y -f
    apt-get install -y nvidia-driver-580 nvidia-dkms-580
}

dpkg -l | grep -q "nvidia-driver-580" || command -v nvidia-smi &>/dev/null || { log_error "NVIDIA Driver installation failed"; exit 1; }
log_success "Step 2 complete: NVIDIA Driver 580+ installed"

# =============================================================================
# STEP 3: Install CUDA Toolkit 12.3
# =============================================================================
log_info "Step 3: Installing CUDA Toolkit 12.3..."

wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
dpkg -i cuda-keyring_1.1-1_all.deb && rm -f cuda-keyring_1.1-1_all.deb
apt-get update -qq && apt-get install -y cuda-toolkit-12-3

cat > /etc/profile.d/cuda.sh << 'EOF'
export CUDA_HOME=/usr/local/cuda-12.3
export PATH=/usr/local/cuda-12.3/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-12.3/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
EOF
chmod +x /etc/profile.d/cuda.sh
ln -sf /usr/local/cuda-12.3 /usr/local/cuda

export CUDA_HOME=/usr/local/cuda-12.3
export PATH=/usr/local/cuda-12.3/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-12.3/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

log_success "Step 3 complete: CUDA Toolkit 12.3 installed"

# =============================================================================
# STEP 4: Build and Install CRIU from Source
# =============================================================================
log_info "Step 4: Building CRIU from source..."

apt-get install -y git pkg-config libprotobuf-dev protobuf-compiler libprotobuf-c-dev \
    protobuf-c-compiler libcap-dev libnl-3-dev libnl-genl-3-dev libnet-dev python3-protobuf \
    asciidoc xmlto libaio-dev uuid-dev python3-pip

rm -rf /tmp/criu && git clone https://github.com/checkpoint-restore/criu.git /tmp/criu
cd /tmp/criu
LATEST_TAG=$(git tag -l | grep -E '^v[0-9]+\.[0-9]+$' | sort -V | tail -1)
[ -n "$LATEST_TAG" ] && git checkout "$LATEST_TAG" && log_info "Checked out CRIU $LATEST_TAG"

make -j$(nproc)
cp criu/criu /usr/local/sbin/ && chmod +x /usr/local/sbin/criu
ln -sf /usr/local/sbin/criu /usr/local/bin/criu

[ -f /usr/local/sbin/criu ] && log_success "CRIU installed: $(/usr/local/sbin/criu --version 2>&1 | head -1)" || { log_error "CRIU installation failed"; exit 1; }
log_success "Step 4 complete: CRIU installed"

# =============================================================================
# STEP 5: Install cuda-checkpoint
# =============================================================================
log_info "Step 5: Installing cuda-checkpoint..."

apt-get install -y cmake
rm -rf /tmp/cuda-checkpoint && git clone https://github.com/NVIDIA/cuda-checkpoint.git /tmp/cuda-checkpoint
cd /tmp/cuda-checkpoint

if [ -f "bin/x86_64_Linux/cuda-checkpoint" ]; then
    log_info "Using pre-built cuda-checkpoint binary..."
    cp bin/x86_64_Linux/cuda-checkpoint /usr/local/bin/
else
    log_info "Building cuda-checkpoint from source..."
    mkdir -p build && cd build
    cmake .. -DCMAKE_BUILD_TYPE=Release -DCUDA_TOOLKIT_ROOT_DIR=/usr/local/cuda-12.3
    make -j$(nproc) && make install
fi
chmod +x /usr/local/bin/cuda-checkpoint

[ -f /usr/local/bin/cuda-checkpoint ] && log_success "cuda-checkpoint installed" || { log_error "cuda-checkpoint installation failed"; exit 1; }
log_success "Step 5 complete: cuda-checkpoint installed"

# =============================================================================
# STEP 6: Install NVIDIA Container Toolkit
# =============================================================================
log_info "Step 6: Installing NVIDIA Container Toolkit..."

distribution=$(. /etc/os-release; echo $ID$VERSION_ID)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt-get update -qq && apt-get install -y nvidia-container-toolkit nvidia-container-runtime
log_success "Step 6 complete: NVIDIA Container Toolkit installed"

# =============================================================================
# STEP 7: Install K3s with NVIDIA GPU Support
# =============================================================================
log_info "Step 7: Installing K3s with NVIDIA GPU support..."

[ -f /usr/local/bin/k3s-uninstall.sh ] && /usr/local/bin/k3s-uninstall.sh || true
sleep 3

curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
sleep 15

cat > /etc/crictl.yaml << 'EOF'
runtime-endpoint: unix:///run/k3s/containerd/containerd.sock
image-endpoint: unix:///run/k3s/containerd/containerd.sock
timeout: 10
EOF

mkdir -p /home/ubuntu/.kube
cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/.kube/config
chown -R ubuntu:ubuntu /home/ubuntu/.kube
chmod 600 /home/ubuntu/.kube/config

# Create NVIDIA RuntimeClass
kubectl apply -f - << 'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
EOF

# Deploy NVIDIA Device Plugin
kubectl apply -f - << 'EOF'
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
      containers:
      - name: nvidia-device-plugin-ctr
        image: nvcr.io/nvidia/k8s-device-plugin:v0.14.3
        env:
        - name: FAIL_ON_INIT_ERROR
          value: "false"
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

log_success "Step 7 complete: K3s with NVIDIA GPU support installed"

# =============================================================================
# STEP 8: Configure K3s containerd for NVIDIA + GRIT
# =============================================================================
log_info "Step 8: Configuring K3s containerd for NVIDIA + GRIT runtimes..."

mkdir -p /etc/containerd/conf.d
nvidia-ctk runtime configure --runtime=containerd --config=/etc/containerd/conf.d/99-nvidia.toml --set-as-default

# Copy K3s flannel CNI config
mkdir -p /etc/cni/net.d
[ -f /var/lib/rancher/k3s/agent/etc/cni/net.d/10-flannel.conflist ] && \
    cp /var/lib/rancher/k3s/agent/etc/cni/net.d/10-flannel.conflist /etc/cni/net.d/

# Create GRIT RuntimeClass
kubectl apply -f - << 'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: grit
handler: nvidia
EOF

systemctl restart k3s
sleep 15

# Wait for node ready
for i in {1..60}; do kubectl get nodes 2>/dev/null | grep -q "Ready" && break; sleep 2; done
kubectl wait --for=condition=Ready node --all --timeout=120s || log_warn "Node may not be fully ready"

# CRITICAL: Replace K3s bundled BusyBox tar with GNU tar
# K3s bundles BusyBox which has a limited tar that doesn't support --no-unquote
# CRIU needs GNU tar to dump tmpfs content during checkpoint
log_info "Replacing K3s BusyBox tar with GNU tar for CRIU compatibility..."
for tar_path in /var/lib/rancher/k3s/data/*/bin/tar; do
    if [ -L "$tar_path" ]; then
        rm -f "$tar_path"
        cp /usr/bin/tar "$tar_path"
        log_info "  Replaced: $tar_path"
    fi
done

log_success "Step 8 complete: K3s containerd configured"

# =============================================================================
# STEP 9: Setup NFS for Checkpoint Storage
# =============================================================================
log_info "Step 9: Setting up checkpoint storage..."

if [ "$NFS_MODE" = "server" ]; then
    log_info "Configuring NFS server..."
    apt-get install -y nfs-kernel-server nfs-common
    
    mkdir -p /exports/grit-checkpoints
    chmod 777 /exports/grit-checkpoints
    
    grep -q '/exports/grit-checkpoints' /etc/exports || \
        echo '/exports/grit-checkpoints *(rw,sync,no_subtree_check,no_root_squash)' >> /etc/exports
    
    exportfs -ra
    systemctl enable nfs-kernel-server
    systemctl restart nfs-kernel-server
    
    mkdir -p /mnt/grit-checkpoints
    grep -q '/exports/grit-checkpoints /mnt/grit-checkpoints' /etc/fstab || \
        echo '/exports/grit-checkpoints /mnt/grit-checkpoints none bind 0 0' >> /etc/fstab
    mount --bind /exports/grit-checkpoints /mnt/grit-checkpoints 2>/dev/null || true
    
    NFS_SERVER_IP=$(hostname -I | awk '{print $1}')
    echo "$NFS_SERVER_IP" > /tmp/nfs_server_ip
    log_success "NFS server ready at $NFS_SERVER_IP:/exports/grit-checkpoints"

elif [ "$NFS_MODE" = "client" ] && [ -n "$NFS_SERVER_IP" ]; then
    log_info "Configuring NFS client (server: $NFS_SERVER_IP)..."
    apt-get install -y nfs-common
    
    mkdir -p /mnt/grit-checkpoints
    grep -q "$NFS_SERVER_IP:/exports/grit-checkpoints" /etc/fstab || \
        echo "$NFS_SERVER_IP:/exports/grit-checkpoints /mnt/grit-checkpoints nfs defaults,_netdev 0 0" >> /etc/fstab
    
    mount -t nfs $NFS_SERVER_IP:/exports/grit-checkpoints /mnt/grit-checkpoints 2>/dev/null || \
        log_warn "NFS mount failed - ensure port 2049 is open"
    
    echo "$NFS_SERVER_IP" > /tmp/nfs_server_ip
    log_success "NFS client configured for $NFS_SERVER_IP"

else
    log_info "Setting up local checkpoint storage..."
    mkdir -p /mnt/grit-checkpoints
    chmod 777 /mnt/grit-checkpoints
    hostname -I | awk '{print $1}' > /tmp/nfs_server_ip
fi

log_success "Step 9 complete: Checkpoint storage configured"

# =============================================================================
# STEP 10: Install Docker and nerdctl
# =============================================================================
log_info "Step 10: Installing Docker and nerdctl..."

curl -fsSL https://get.docker.com | sh
usermod -aG docker ubuntu
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

curl -L -o /tmp/nerdctl.tar.gz https://github.com/containerd/nerdctl/releases/download/v2.0.2/nerdctl-2.0.2-linux-amd64.tar.gz
tar -xzf /tmp/nerdctl.tar.gz -C /usr/local/bin nerdctl && chmod +x /usr/local/bin/nerdctl

log_success "Step 10 complete: Docker and nerdctl installed"

# =============================================================================
# STEP 11: Install PyTorch and Worker Utilities
# =============================================================================
log_info "Step 11: Installing PyTorch and worker utilities..."

apt-get install -y python3 python3-pip python3-dev
pip3 install --upgrade pip
pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
pip3 install numpy grpcio kubernetes

log_success "Step 11 complete: PyTorch and utilities installed"

# =============================================================================
# STEP 12: Build pytorch-criu Image
# =============================================================================
log_info "Step 12: Building pytorch-criu container image..."

cat > /tmp/Dockerfile << 'EOF'
FROM pytorch/pytorch:2.1.0-cuda12.1-cudnn8-runtime
# Install utilities needed for CRIU checkpoint (GNU tar is required - not BusyBox)
RUN apt-get update && apt-get install -y \
    iproute2 procps net-tools \
    tar coreutils \
    && rm -rf /var/lib/apt/lists/* \
    && tar --version | head -1
WORKDIR /workspace
EOF

docker build -t pytorch-criu:latest /tmp/
docker save pytorch-criu:latest | k3s ctr images import -

crictl images | grep -q pytorch-criu && log_success "pytorch-criu image available" || log_warn "pytorch-criu image may not be imported"
log_success "Step 12 complete: pytorch-criu image built"

# =============================================================================
# STEP 13: Install Helm
# =============================================================================
log_info "Step 13: Installing Helm..."

curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

command -v helm &>/dev/null && log_success "Helm installed: $(helm version --short)" || { log_error "Helm installation failed"; exit 1; }
log_success "Step 13 complete: Helm installed"

# =============================================================================
# STEP 14: Clone GRIT Repository and Install via Helm
# =============================================================================
log_info "Step 14: Installing GRIT via Helm..."

# CRITICAL: Set KUBECONFIG for K3s (required for Helm to work with sudo)
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# GitHub Container Registry credentials (for pulling private images)
GHCR_USERNAME="krish-parmar22"
GHCR_TOKEN="secret"

# Remove old GRIT resources (shell-based version if exists)
log_info "Cleaning up old GRIT resources..."
kubectl delete crds checkpoints.grit.cumulus.dev restores.grit.cumulus.dev migrations.grit.cumulus.dev 2>/dev/null || true
kubectl delete configmap grit-agent-script -n grit-system 2>/dev/null || true
kubectl delete daemonset grit-agent -n grit-system 2>/dev/null || true

# Delete namespace and wait for it to fully terminate
if kubectl get namespace grit-system &>/dev/null; then
    log_info "Deleting existing grit-system namespace..."
    kubectl delete namespace grit-system --wait=false 2>/dev/null || true
    # Wait for namespace to be fully deleted
    for i in {1..60}; do
        kubectl get namespace grit-system &>/dev/null || break
        log_info "  Waiting for namespace deletion... ($i/60)"
        sleep 2
    done
fi

# Clone GRIT repository
GRIT_DIR="/opt/grit"
rm -rf "$GRIT_DIR"
git clone --branch "$GRIT_BRANCH" "$GRIT_REPO" "$GRIT_DIR"

# Remove the AKS-specific nodeSelector from grit-manager template
log_info "Patching Helm chart for K3s compatibility..."
sed -i '/nodeSelector:/,/agentpool: agentpool/d' "$GRIT_DIR/charts/grit-manager/templates/grit-manager.yaml" 2>/dev/null || true

# Create namespace
log_info "Creating grit-system namespace..."
kubectl create namespace grit-system

# Create GHCR pull secret
log_info "Creating GHCR pull secret..."
kubectl create secret docker-registry ghcr-secret \
    -n grit-system \
    --docker-server=ghcr.io \
    --docker-username="$GHCR_USERNAME" \
    --docker-password="$GHCR_TOKEN" || true

# Create NFS PV and PVC for checkpoints
NFS_IP=$(cat /tmp/nfs_server_ip 2>/dev/null || hostname -I | awk '{print $1}')

kubectl apply -f - << EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-checkpoint
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: Immediate
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: grit-checkpoint-pv
spec:
  capacity:
    storage: 500Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: nfs-checkpoint
  hostPath:
    path: /mnt/grit-checkpoints
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: grit-checkpoint-pvc
  namespace: grit-system
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-checkpoint
  resources:
    requests:
      storage: 500Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: grit-checkpoint-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-checkpoint
  resources:
    requests:
      storage: 500Gi
EOF

# Create values override for K3s
cat > /tmp/grit-values-k3s.yaml << 'EOF'
log:
  level: 5

replicaCount: 1
certDuration: 87600h
hostPath: /mnt/grit-checkpoints

image:
  gritmanager:
    registry: ghcr.io
    repository: cumulus-compute-labs/grit-manager
    tag: dev
    pullSecrets: []
  gritagent:
    registry: ghcr.io
    repository: cumulus-compute-labs/grit-agent
    tag: dev
    pullSecrets: []

ports:
  metrics: 10351
  webhook: 10350
  healthProbe: 10352

resources:
  limits:
    cpu: 2000m
    memory: 1024Mi
  requests:
    cpu: 200m
    memory: 256Mi
EOF

# Install GRIT via Helm
log_info "Installing GRIT Helm chart..."
helm upgrade --install grit-manager "$GRIT_DIR/charts/grit-manager" \
    -n grit-system \
    -f /tmp/grit-values-k3s.yaml \
    --wait --timeout 5m || log_warn "Helm install completed with warnings"

# CRITICAL: Patch service account to use pull secret (Helm chart doesn't support this directly)
log_info "Patching service account with pull secret..."
kubectl patch serviceaccount grit-manager-sa -n grit-system \
    -p '{"imagePullSecrets": [{"name": "ghcr-secret"}]}' || true

# Delete the pod so it restarts with the new pull secret
kubectl delete pod -n grit-system -l app.kubernetes.io/name=grit-manager 2>/dev/null || true

# Wait for pod to be ready
log_info "Waiting for GRIT manager pod to be ready..."
for i in {1..60}; do
    READY=$(kubectl get pods -n grit-system -l app.kubernetes.io/name=grit-manager -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)
    [ "$READY" = "true" ] && break
    sleep 3
done

# Verify installation
kubectl get crds | grep -E 'checkpoint|restore' && log_success "GRIT CRDs installed"
kubectl get pods -n grit-system && log_success "GRIT pods deployed"

log_success "Step 14 complete: GRIT installed via Helm"

# =============================================================================
# STEP 15: Install GRIT CLI
# =============================================================================
log_info "Step 15: Installing GRIT CLI..."

cat > /usr/local/bin/grit << 'CLIEOF'
#!/bin/bash
# GRIT CLI - GPU Runtime for Iterative Training
set -e

NS="${NAMESPACE:-default}"
API_GROUP="kaito.sh"
API_VERSION="v1alpha1"

usage() {
    echo "GRIT - GPU Runtime for Iterative Training"
    echo ""
    echo "Usage: grit <command> [args]"
    echo ""
    echo "Commands:"
    echo "  checkpoint <pod>              Create checkpoint of a pod"
    echo "  restore <checkpoint>          Restore from a checkpoint"
    echo "  status                        Show all GRIT resources"
    echo "  list                          List checkpoints and restores"
    echo ""
    echo "Options:"
    echo "  --wait                        Wait for operation to complete"
    echo "  -n, --namespace <ns>          Specify namespace (default: default)"
}

gen_id() { echo "$(date +%s)-$(head -c4 /dev/urandom | xxd -p)"; }

cmd_checkpoint() {
    local pod=$1 wait=false pvc=""
    shift || true
    while [[ $# -gt 0 ]]; do
        case $1 in
            --wait) wait=true; shift ;;
            --pvc) pvc=$2; shift 2 ;;
            *) shift ;;
        esac
    done
    
    [ -z "$pod" ] && { echo "Usage: grit checkpoint <pod> [--pvc <claim>] [--wait]"; exit 1; }
    
    local name="ckpt-$(gen_id)"
    
    if [ -n "$pvc" ]; then
        kubectl apply -f - << EOF
apiVersion: ${API_GROUP}/${API_VERSION}
kind: Checkpoint
metadata:
  name: $name
  namespace: $NS
spec:
  podName: $pod
  volumeClaim:
    claimName: $pvc
EOF
    else
        kubectl apply -f - << EOF
apiVersion: ${API_GROUP}/${API_VERSION}
kind: Checkpoint
metadata:
  name: $name
  namespace: $NS
spec:
  podName: $pod
EOF
    fi
    
    echo "Created checkpoint: $name"
    
    if $wait; then
        echo "Waiting for checkpoint to complete..."
        while true; do
            phase=$(kubectl get checkpoint "$name" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
            echo "  Phase: $phase"
            [ "$phase" = "Checkpointed" ] || [ "$phase" = "Submitted" ] && break
            [ "$phase" = "Failed" ] && { echo "Checkpoint failed!"; exit 1; }
            sleep 3
        done
    fi
}

cmd_restore() {
    local checkpoint=$1 wait=false
    shift || true
    [[ "$*" == *--wait* ]] && wait=true
    
    [ -z "$checkpoint" ] && { echo "Usage: grit restore <checkpoint-name> [--wait]"; exit 1; }
    
    local name="rst-$(gen_id)"
    
    kubectl apply -f - << EOF
apiVersion: ${API_GROUP}/${API_VERSION}
kind: Restore
metadata:
  name: $name
  namespace: $NS
spec:
  checkpointName: $checkpoint
EOF
    
    echo "Created restore: $name"
    
    if $wait; then
        echo "Waiting for restore to complete..."
        while true; do
            phase=$(kubectl get restore "$name" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
            echo "  Phase: $phase"
            [ "$phase" = "Restored" ] && break
            [ "$phase" = "Failed" ] && { echo "Restore failed!"; exit 1; }
            sleep 3
        done
    fi
}

cmd_status() {
    echo "=== GRIT Status ==="
    echo ""
    echo "Checkpoints:"
    kubectl get checkpoints -A 2>/dev/null || echo "  None"
    echo ""
    echo "Restores:"
    kubectl get restores -A 2>/dev/null || echo "  None"
    echo ""
    echo "GRIT Manager:"
    kubectl get pods -n grit-system -l app.kubernetes.io/name=grit-manager 2>/dev/null || echo "  Not running"
    echo ""
    echo "PVCs:"
    kubectl get pvc -A 2>/dev/null | grep grit || echo "  None"
}

cmd_list() { cmd_status; }

# Parse global options
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace) NS="$2"; shift 2 ;;
        checkpoint) shift; cmd_checkpoint "$@"; exit 0 ;;
        restore) shift; cmd_restore "$@"; exit 0 ;;
        status|list) cmd_status; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

usage
CLIEOF

chmod +x /usr/local/bin/grit
log_success "Step 15 complete: GRIT CLI installed"

# =============================================================================
# STEP 16: Create Validation Script
# =============================================================================
log_info "Step 16: Creating validation script..."

cat > /usr/local/bin/validate-grit-setup.sh << 'EOF'
#!/bin/bash
echo "=========================================="
echo "GRIT GPU Worker Node Validation"
echo "=========================================="
echo ""

check() { command -v $1 &>/dev/null && echo "✓ $1" || echo "✗ $1 not found"; }

echo "1. Core Binaries:"
check nvidia-smi
check nvcc
check criu
check cuda-checkpoint
check kubectl
check docker
check helm
check grit
echo ""

echo "2. NVIDIA Driver:"
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null || echo "  Driver not loaded (reboot required?)"
echo ""

echo "3. K3s Status:"
kubectl get nodes 2>/dev/null || echo "  K3s not running"
echo ""

echo "4. RuntimeClasses:"
kubectl get runtimeclass 2>/dev/null | grep -E 'nvidia|grit' || echo "  No GPU runtimes"
echo ""

echo "5. GRIT CRDs:"
kubectl get crds 2>/dev/null | grep -E 'checkpoint|restore' || echo "  No GRIT CRDs"
echo ""

echo "6. GRIT Manager:"
kubectl get pods -n grit-system 2>/dev/null || echo "  Not deployed"
echo ""

echo "7. Checkpoint Storage:"
[ -d /mnt/grit-checkpoints ] && echo "✓ /mnt/grit-checkpoints exists" || echo "✗ Checkpoint dir not found"
df -h /mnt/grit-checkpoints 2>/dev/null | tail -1 || true
echo ""

echo "8. PVCs:"
kubectl get pvc -A 2>/dev/null | grep grit || echo "  No GRIT PVCs"
echo ""

echo "9. GPU in K8s:"
kubectl describe nodes | grep -A5 'Allocatable:' | grep nvidia || echo "  GPU not visible (reboot required?)"
echo ""

echo "10. PyTorch CUDA:"
python3 -c "import torch; print(f'PyTorch {torch.__version__}, CUDA: {torch.cuda.is_available()}')" 2>/dev/null || echo "  PyTorch not installed"
echo ""

echo "=========================================="
echo "Quick Commands:"
echo "  grit checkpoint <pod>    # Checkpoint a pod"
echo "  grit restore <ckpt>      # Restore from checkpoint"
echo "  grit status              # Show all resources"
echo "=========================================="
EOF

chmod +x /usr/local/bin/validate-grit-setup.sh
log_success "Step 16 complete: Validation script created"

# =============================================================================
# Summary
# =============================================================================
echo ""
log_success "=========================================="
log_success "GRIT Setup Complete!"
log_success "=========================================="
echo ""
echo "Installed:"
echo "  ✓ NVIDIA Driver 580+ + CUDA 12.3"
echo "  ✓ CRIU + cuda-checkpoint"
echo "  ✓ K3s with NVIDIA + GRIT runtimes"
echo "  ✓ Docker + nerdctl"
echo "  ✓ Helm"
echo "  ✓ GRIT (via Helm chart)"
echo "  ✓ GRIT CLI (/usr/local/bin/grit)"
echo "  ✓ PyTorch with CUDA"

if [ "$NFS_MODE" = "server" ]; then
    echo "  ✓ NFS Server at $(cat /tmp/nfs_server_ip):/exports/grit-checkpoints"
elif [ "$NFS_MODE" = "client" ]; then
    echo "  ✓ NFS Client mounted from $NFS_SERVER_IP"
else
    echo "  ✓ Local checkpoint storage at /mnt/grit-checkpoints"
fi

echo ""
log_warn "REBOOT REQUIRED to load NVIDIA kernel modules"
echo ""
echo "After reboot, run:"
echo "  /usr/local/bin/validate-grit-setup.sh"
echo ""
echo "Usage:"
echo "  grit checkpoint <pod-name>       # Checkpoint a pod"
echo "  grit restore <checkpoint-name>   # Restore from checkpoint"
echo "  grit status                      # Show all GRIT resources"
echo ""


