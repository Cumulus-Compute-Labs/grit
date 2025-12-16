#!/bin/bash
# =============================================================================
# Install GRIT Containerd Shim
# =============================================================================
# This script builds and installs the containerd-shim-grit-v1 on K3s nodes
# to enable CRIU-based container checkpointing.
# =============================================================================

set -eo pipefail

# Configuration
SOURCE_HOST="${SOURCE_HOST:-163.192.28.24}"
DEST_HOST="${DEST_HOST:-192.9.133.23}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-~/.ssh/krish_key}"

# Expand ~ 
SSH_KEY="${SSH_KEY/#\~/$HOME}"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no"

log_info() { echo "[INFO] $1"; }
log_success() { echo "[SUCCESS] $1"; }
log_error() { echo "[ERROR] $1" >&2; }

# =============================================================================
# Step 1: Build the shim locally
# =============================================================================
log_info "Step 1: Building containerd-shim-grit-v1..."

cd "$(dirname "$0")/.."

# Build for linux/amd64
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build \
    -ldflags "-s -w" \
    -o _output/containerd-shim-grit-v1 \
    -tags "urfave_cli_no_docs no_grpc" \
    ./cmd/containerd-shim-grit-v1

if [ ! -f "_output/containerd-shim-grit-v1" ]; then
    log_error "Failed to build shim"
    exit 1
fi
log_success "Shim built: _output/containerd-shim-grit-v1"

# =============================================================================
# Step 2: Copy shim to nodes
# =============================================================================
log_info "Step 2: Copying shim to nodes..."

for HOST in $SOURCE_HOST $DEST_HOST; do
    log_info "  Copying to $HOST..."
    scp $SSH_OPTS _output/containerd-shim-grit-v1 ${SSH_USER}@${HOST}:/tmp/
    
    ssh $SSH_OPTS ${SSH_USER}@${HOST} "
        sudo mv /tmp/containerd-shim-grit-v1 /usr/local/bin/
        sudo chmod +x /usr/local/bin/containerd-shim-grit-v1
        echo '  Installed: /usr/local/bin/containerd-shim-grit-v1'
    "
done
log_success "Shim installed on both nodes"

# =============================================================================
# Step 3: Configure containerd to use the grit runtime
# =============================================================================
log_info "Step 3: Configuring containerd for grit runtime..."

for HOST in $SOURCE_HOST $DEST_HOST; do
    log_info "  Configuring $HOST..."
    ssh $SSH_OPTS ${SSH_USER}@${HOST} '
        # K3s containerd config location
        CONTAINERD_CONFIG="/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl"
        
        # Check if grit runtime already configured
        if sudo grep -q "containerd-shim-grit-v1" "$CONTAINERD_CONFIG" 2>/dev/null; then
            echo "    Grit runtime already configured"
        else
            # Create config template if it does not exist
            sudo mkdir -p /var/lib/rancher/k3s/agent/etc/containerd
            
            # Get the existing config as a base (K3s generates one)
            if [ ! -f "$CONTAINERD_CONFIG" ]; then
                # Copy the generated config as template
                sudo cp /var/lib/rancher/k3s/agent/etc/containerd/config.toml "$CONTAINERD_CONFIG" 2>/dev/null || true
            fi
            
            # Add grit runtime to containerd config
            # The grit shim wraps runc and adds CRIU checkpoint support
            sudo tee -a "$CONTAINERD_CONFIG" > /dev/null << '\''EOF'\''

# GRIT runtime for CRIU checkpointing (GPU-compatible)
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.grit]
  runtime_type = "io.containerd.runc.v2"
  privileged_without_host_devices = false
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.grit.options]
    BinaryName = "/usr/local/bin/containerd-shim-grit-v1"
    SystemdCgroup = true
EOF
            echo "    Added grit runtime to containerd config"
        fi
        
        # Restart K3s to pick up the new config
        echo "    Restarting K3s..."
        sudo systemctl restart k3s || sudo systemctl restart k3s-agent || true
    '
done

log_info "Waiting for K3s to stabilize..."
sleep 10
log_success "Containerd configured"

# =============================================================================
# Step 4: Create RuntimeClass for grit
# =============================================================================
log_info "Step 4: Creating RuntimeClass..."

ssh $SSH_OPTS ${SSH_USER}@${SOURCE_HOST} "
    kubectl apply -f - << 'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: grit
handler: grit
EOF
"
log_success "RuntimeClass 'grit' created"

# =============================================================================
# Step 5: Verify installation
# =============================================================================
log_info "Step 5: Verifying installation..."

ssh $SSH_OPTS ${SSH_USER}@${SOURCE_HOST} "
    echo 'RuntimeClasses:'
    kubectl get runtimeclass
    echo ''
    echo 'Testing shim:'
    /usr/local/bin/containerd-shim-grit-v1 --version 2>/dev/null || echo '  (shim does not support --version)'
    ls -la /usr/local/bin/containerd-shim-grit-v1
"

log_success "=============================================="
log_success "GRIT Shim Installation Complete!"
log_success "=============================================="
echo ""
echo "Next steps:"
echo "1. Update your pod to use: runtimeClassName: grit"
echo "2. Re-run the migration: ./test2/grit-gpu-migrate.sh --deploy"
echo ""
