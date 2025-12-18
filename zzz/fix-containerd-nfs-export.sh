#!/bin/bash
# Fix containerd overlayfs to enable nfs_export for CRIU fsnotify support

echo "=== Enabling nfs_export=on for overlayfs snapshotter ==="

# Backup current config
sudo cp /etc/containerd/config.toml /etc/containerd/config.toml.bak
echo "Backed up config to /etc/containerd/config.toml.bak"

# Add overlayfs snapshotter config with nfs_export=on
# Need to add this section to the config
sudo tee -a /etc/containerd/config.toml > /dev/null << 'EOF'

# Enable nfs_export for CRIU fsnotify support
[plugins."io.containerd.snapshotter.v1.overlayfs"]
  mount_options = ["index=on", "nfs_export=on"]
EOF

echo ""
echo "Updated config:"
cat /etc/containerd/config.toml

echo ""
echo "=== Restarting k3s (includes containerd) ==="
sudo systemctl restart k3s

echo ""
echo "Waiting for k3s to be ready..."
sleep 10

# Check k3s status
sudo systemctl status k3s --no-pager | head -10

echo ""
echo "=== Verification ==="
echo "Checking overlayfs mounts (new containers will have nfs_export)..."
mount | grep overlay | head -3

echo ""
echo "Done! New containers will now mount overlayfs with nfs_export=on"
echo "You need to RECREATE the test pod for the fix to take effect."

