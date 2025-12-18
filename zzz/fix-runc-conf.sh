#!/bin/bash
# Option 3: Revert shim to default and configure runc.conf for GPU restore

set -e

echo "=== Step 1: Create /etc/criu/runc.conf with GPU-compatible flags ==="
sudo mkdir -p /etc/criu
sudo tee /etc/criu/runc.conf > /dev/null << 'EOF'
# CRIU options for GPU container checkpoint/restore via runc
# These flags are passed to CRIU when runc calls it

# Network options
tcp-established
ext-unix-sk

# Mount namespace compatibility - CRITICAL for GPU containers
# Uses old mount engine to avoid mount-v2 sharing issues
mntns-compat-mode

# Handle external mount masters (for nested containers/shared mounts)
enable-external-masters
enable-external-sharing

# Shell job support
shell-job

# Force inode reverse mapping (for overlayfs)
force-irmap

# Skip in-flight connections
skip-in-flight
EOF

echo "Created /etc/criu/runc.conf"
cat /etc/criu/runc.conf

echo ""
echo "=== Step 2: Restore original GRIT shim (from backup or rebuild) ==="

# Check if backup exists
if [ -f /usr/local/bin/containerd-shim-grit-v1.backup ]; then
    echo "Restoring from backup..."
    sudo systemctl stop k3s
    sleep 2
    sudo pkill -9 -f "containerd-shim-grit" || true
    sleep 2
    sudo cp /usr/local/bin/containerd-shim-grit-v1.backup /usr/local/bin/containerd-shim-grit-v1
    sudo chmod +x /usr/local/bin/containerd-shim-grit-v1
else
    echo "No backup found. Rebuilding original shim..."
    
    cd /tmp
    rm -rf /tmp/shim-rebuild 2>/dev/null || true
    mkdir -p /tmp/shim-rebuild
    
    # Clone fresh GRIT repo (original code without modifications)
    git clone --depth 1 https://github.com/kaito-project/grit.git /tmp/shim-rebuild/grit-src
    cd /tmp/shim-rebuild/grit-src
    
    # Build original shim
    export PATH=/usr/local/go/bin:$PATH
    export GOROOT=/usr/local/go
    go build -o /tmp/shim-rebuild/containerd-shim-grit-v1 ./cmd/containerd-shim-grit-v1
    
    # Deploy
    sudo systemctl stop k3s
    sleep 2
    sudo pkill -9 -f "containerd-shim-grit" || true
    sleep 2
    sudo cp /tmp/shim-rebuild/containerd-shim-grit-v1 /usr/local/bin/containerd-shim-grit-v1
    sudo chmod +x /usr/local/bin/containerd-shim-grit-v1
fi

echo ""
echo "=== Step 3: Start k3s ==="
sudo systemctl start k3s
sleep 15

echo ""
echo "=== Step 4: Verify ==="
echo "runc.conf contents:"
cat /etc/criu/runc.conf

echo ""
echo "Shim version:"
ls -la /usr/local/bin/containerd-shim-grit-v1

echo ""
echo "Cluster status:"
kubectl get nodes

echo ""
echo "=== Done! Now test checkpoint/restore ==="
