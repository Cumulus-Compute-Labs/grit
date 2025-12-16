#!/bin/bash
# =============================================================================
# GRIT Setup Fix Script
# =============================================================================
# Fixes the GRIT setup for two-node GPU migration:
# 1. Copies real GRIT shim to dest node
# 2. Sets up SSH key trust between nodes  
# 3. Joins dest node to source's K3s cluster as worker
# 4. Configures NFS for checkpoint storage
# =============================================================================

set -eo pipefail

# Configuration
SOURCE_HOST="163.192.28.24"
DEST_HOST="192.9.133.23"
SSH_USER="ubuntu"
SSH_KEY="${SSH_KEY:-~/.ssh/krish_key}"
SSH_KEY="${SSH_KEY/#\~/$HOME}"

SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SSH_SRC="ssh $SSH_OPTS ${SSH_USER}@${SOURCE_HOST}"
SSH_DST="ssh $SSH_OPTS ${SSH_USER}@${DEST_HOST}"
SCP_SRC="scp $SSH_OPTS"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${GREEN}========== $1 ==========${NC}\n"; }

# =============================================================================
# STEP 1: Copy Real GRIT Shim to Dest Node
# =============================================================================
log_step "STEP 1: Copy Real GRIT Shim to Dest Node"

log_info "Downloading shim from source to local machine..."
$SCP_SRC ${SSH_USER}@${SOURCE_HOST}:/usr/local/bin/containerd-shim-grit-v1 /tmp/containerd-shim-grit-v1

log_info "Uploading shim to dest node..."
$SCP_SRC /tmp/containerd-shim-grit-v1 ${SSH_USER}@${DEST_HOST}:/tmp/containerd-shim-grit-v1

log_info "Installing shim on dest node..."
$SSH_DST "sudo mv /tmp/containerd-shim-grit-v1 /usr/local/bin/ && sudo chmod +x /usr/local/bin/containerd-shim-grit-v1"

# Verify
DEST_SHIM_SIZE=$($SSH_DST "stat -c%s /usr/local/bin/containerd-shim-grit-v1")
if [ "$DEST_SHIM_SIZE" -gt 1000000 ]; then
    log_success "Real GRIT shim installed on dest node (${DEST_SHIM_SIZE} bytes)"
else
    log_error "Shim installation failed - file too small"
    exit 1
fi

# =============================================================================
# STEP 2: Setup SSH Key Trust Between Nodes
# =============================================================================
log_step "STEP 2: Setup SSH Key Trust Between Nodes"

log_info "Getting/creating SSH key on source node..."
$SSH_SRC "
    if [ ! -f ~/.ssh/id_rsa ]; then
        ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa
    fi
    cat ~/.ssh/id_rsa.pub
" > /tmp/source_pubkey.txt

log_info "Adding source's key to dest's authorized_keys..."
$SSH_DST "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
cat /tmp/source_pubkey.txt | $SSH_DST "cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

log_info "Getting dest's host key..."
DEST_HOSTKEY=$($SSH_DST "cat /etc/ssh/ssh_host_ecdsa_key.pub")

log_info "Adding dest's host key to source's known_hosts..."
$SSH_SRC "echo '$DEST_HOST ${DEST_HOSTKEY}' >> ~/.ssh/known_hosts"
$SSH_SRC "echo '192.9.133.23 ${DEST_HOSTKEY}' >> ~/.ssh/known_hosts"

log_info "Testing SSH from source to dest..."
$SSH_SRC "ssh -o StrictHostKeyChecking=no ${SSH_USER}@${DEST_HOST} 'echo SSH from source to dest: SUCCESS'"

log_success "SSH trust established between nodes"

# =============================================================================
# STEP 3: Uninstall K3s from Dest Node (Prepare for Worker Join)
# =============================================================================
log_step "STEP 3: Prepare Dest Node for K3s Worker Join"

log_info "Stopping K3s on dest node..."
$SSH_DST "
    if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
        sudo /usr/local/bin/k3s-uninstall.sh || true
    fi
    sleep 5
"

log_info "Getting K3s join token from source node..."
K3S_TOKEN=$($SSH_SRC "sudo cat /var/lib/rancher/k3s/server/node-token")
log_info "Got K3s token: ${K3S_TOKEN:0:20}..."

# =============================================================================
# STEP 4: Join Dest Node to Source's K3s Cluster
# =============================================================================
log_step "STEP 4: Join Dest Node to Source's K3s Cluster"

log_info "Installing K3s agent on dest node..."
$SSH_DST "
    curl -sfL https://get.k3s.io | K3S_URL='https://${SOURCE_HOST}:6443' K3S_TOKEN='${K3S_TOKEN}' sh -s - agent
    sleep 15
"

log_info "Waiting for node to join cluster..."
for i in {1..30}; do
    NODES=$($SSH_SRC "kubectl get nodes --no-headers 2>/dev/null | wc -l")
    if [ "$NODES" -ge 2 ]; then
        break
    fi
    echo "  Waiting for dest node to join... ($i/30)"
    sleep 5
done

$SSH_SRC "kubectl get nodes"

# =============================================================================
# STEP 5: Configure Containerd on Dest Node
# =============================================================================
log_step "STEP 5: Configure Containerd on Dest Node"

log_info "Configuring NVIDIA runtime on dest node..."
$SSH_DST "
    # Configure crictl
    sudo tee /etc/crictl.yaml > /dev/null << 'EOF'
runtime-endpoint: unix:///run/k3s/containerd/containerd.sock
image-endpoint: unix:///run/k3s/containerd/containerd.sock
timeout: 10
EOF

    # Configure containerd for NVIDIA + GRIT
    sudo mkdir -p /var/lib/rancher/k3s/agent/etc/containerd
    
    # Create containerd config template
    sudo tee /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl > /dev/null << 'EOFCONTAINERD'
version = 2

[plugins.\"io.containerd.grpc.v1.cri\".containerd]
  default_runtime_name = \"nvidia\"

[plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.nvidia]
  runtime_type = \"io.containerd.runc.v2\"
  privileged_without_host_devices = false
  [plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.nvidia.options]
    BinaryName = \"/usr/bin/nvidia-container-runtime\"
    SystemdCgroup = true

[plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.grit]
  runtime_type = \"io.containerd.runc.v2\"
  privileged_without_host_devices = false
  [plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.grit.options]
    BinaryName = \"/usr/local/bin/containerd-shim-grit-v1\"
    SystemdCgroup = true
EOFCONTAINERD

    # Restart K3s agent
    sudo systemctl restart k3s-agent
    sleep 10
"

log_success "Containerd configured on dest node"

# =============================================================================
# STEP 6: Setup NFS for Checkpoint Storage
# =============================================================================
log_step "STEP 6: Setup NFS for Checkpoint Storage"

log_info "Configuring NFS server on source node..."
$SSH_SRC "
    sudo apt-get install -y nfs-kernel-server nfs-common
    
    sudo mkdir -p /exports/grit-checkpoints
    sudo chmod 777 /exports/grit-checkpoints
    
    grep -q '/exports/grit-checkpoints' /etc/exports || \
        echo '/exports/grit-checkpoints *(rw,sync,no_subtree_check,no_root_squash)' | sudo tee -a /etc/exports
    
    sudo exportfs -ra
    sudo systemctl enable nfs-kernel-server
    sudo systemctl restart nfs-kernel-server
    
    # Also create local mount point
    sudo mkdir -p /mnt/grit-checkpoints
    sudo mount --bind /exports/grit-checkpoints /mnt/grit-checkpoints 2>/dev/null || true
"

log_info "Configuring NFS client on dest node..."
$SSH_DST "
    sudo apt-get install -y nfs-common
    
    sudo mkdir -p /mnt/grit-checkpoints
    
    # Mount NFS from source
    sudo mount -t nfs ${SOURCE_HOST}:/exports/grit-checkpoints /mnt/grit-checkpoints || \
        echo 'NFS mount may already exist'
    
    # Add to fstab for persistence
    grep -q '${SOURCE_HOST}:/exports/grit-checkpoints' /etc/fstab || \
        echo '${SOURCE_HOST}:/exports/grit-checkpoints /mnt/grit-checkpoints nfs defaults,_netdev 0 0' | sudo tee -a /etc/fstab
"

# Test NFS
log_info "Testing NFS..."
$SSH_SRC "echo 'test-$(date +%s)' | sudo tee /mnt/grit-checkpoints/nfs-test.txt"
TEST_CONTENT=$($SSH_DST "cat /mnt/grit-checkpoints/nfs-test.txt 2>/dev/null || echo 'FAILED'")
if [[ "$TEST_CONTENT" == test-* ]]; then
    log_success "NFS working between nodes"
else
    log_warn "NFS test failed - checkpoints may not transfer properly"
fi

# =============================================================================
# STEP 7: Create RuntimeClasses and PVCs
# =============================================================================
log_step "STEP 7: Create RuntimeClasses and Storage"

log_info "Creating RuntimeClasses..."
$SSH_SRC "
    kubectl apply -f - << 'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
---
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: grit
handler: grit
EOF
"

log_info "Creating Checkpoint PVC..."
$SSH_SRC "
    kubectl apply -f - << 'EOF'
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
  namespace: default
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
  namespace: grit-system
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-checkpoint
  resources:
    requests:
      storage: 500Gi
EOF
"

log_success "Storage configured"

# =============================================================================
# STEP 8: Verify GRIT Manager is Running
# =============================================================================
log_step "STEP 8: Verify GRIT Manager"

log_info "Checking GRIT manager status..."
$SSH_SRC "
    kubectl get pods -n grit-system
    echo ''
    kubectl get crds | grep -E 'checkpoint|restore' || echo 'No GRIT CRDs found'
"

# =============================================================================
# Summary
# =============================================================================
log_step "SETUP COMPLETE"

echo ""
echo "Two-Node GRIT Cluster:"
$SSH_SRC "kubectl get nodes -o wide"
echo ""
echo "RuntimeClasses:"
$SSH_SRC "kubectl get runtimeclass"
echo ""
echo "Next Steps:"
echo "  1. Run: ./test/migrate.sh --deploy"
echo "  2. This will deploy a training pod, checkpoint it, and restore on the other node"
echo ""
