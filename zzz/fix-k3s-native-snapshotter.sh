#!/bin/bash
# Switch k3s to native snapshotter to avoid overlayfs fsnotify issues

echo "=== Switching k3s to Native Snapshotter ==="

# Step 1: Create k3s config with native snapshotter
echo "Step 1: Creating k3s config with native snapshotter..."
sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/config.yaml > /dev/null << 'EOF'
snapshotter: native
EOF

echo "Config created:"
cat /etc/rancher/k3s/config.yaml

# Step 2: Stop k3s
echo ""
echo "Step 2: Stopping k3s..."
sudo systemctl stop k3s
sleep 5

# Step 3: Start k3s
echo "Step 3: Starting k3s with native snapshotter..."
sudo systemctl start k3s

echo "Waiting for k3s..."
sleep 20

# Step 4: Verify
echo ""
echo "Step 4: Verifying..."
echo "=== k3s status ==="
sudo systemctl status k3s --no-pager | head -5

echo ""
echo "=== Checking snapshotter ==="
sudo crictl info 2>/dev/null | grep -i snapshotter || echo "crictl info not available"

echo ""
echo "=== Current pods ==="
kubectl get pods -A 2>/dev/null | head -10

echo ""
echo "Done! Native snapshotter should now be active."
echo "Create a new pod to test - it won't use overlayfs."

