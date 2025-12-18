#!/bin/bash
# Fix k3s containerd to enable nfs_export for overlayfs

echo "=== Fixing k3s containerd for nfs_export ==="

# Step 1: Stop k3s
echo "Step 1: Stopping k3s..."
sudo systemctl stop k3s
sleep 3

# Step 2: Create template directory
echo "Step 2: Creating template directory..."
sudo mkdir -p /var/lib/rancher/k3s/agent/etc/containerd

# Step 3: Create config.toml.tmpl
echo "Step 3: Creating config.toml.tmpl with nfs_export=on..."
sudo tee /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl > /dev/null << 'EOF'
# k3s containerd config template with nfs_export for CRIU support
[plugins."io.containerd.snapshotter.v1.overlayfs"]
    mount_options = ["index=on", "nfs_export=on"]
EOF

echo "Template created:"
cat /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl

# Step 4: Start k3s
echo ""
echo "Step 4: Starting k3s..."
sudo systemctl start k3s

echo "Waiting for k3s..."
sleep 15

# Step 5: Verify
echo ""
echo "Step 5: Verifying configuration..."
echo "=== Generated containerd config ==="
sudo grep -A 2 "overlayfs" /var/lib/rancher/k3s/agent/etc/containerd/config.toml 2>/dev/null || echo "Config section not found yet"

echo ""
echo "=== k3s status ==="
sudo systemctl status k3s --no-pager | head -5

echo ""
echo "Done! Now delete and recreate pods to test with nfs_export=on"

