#!/bin/bash
# Fix k3s snapshotter via systemd service file

echo "=== Fixing k3s snapshotter via systemd ==="

# Step 1: Stop k3s
echo "Step 1: Stopping k3s..."
sudo systemctl stop k3s
sleep 5

# Step 2: Check current ExecStart
echo ""
echo "Step 2: Current k3s.service ExecStart:"
grep "ExecStart" /etc/systemd/system/k3s.service

# Step 3: Modify the service file to add --snapshotter=native
echo ""
echo "Step 3: Adding --snapshotter=native to service..."
sudo sed -i 's|ExecStart=/usr/local/bin/k3s server|ExecStart=/usr/local/bin/k3s server --snapshotter=native|' /etc/systemd/system/k3s.service

# Check if change was applied
echo "After modification:"
grep "ExecStart" /etc/systemd/system/k3s.service

# Step 4: Reload systemd and restart k3s
echo ""
echo "Step 4: Reloading systemd and starting k3s..."
sudo systemctl daemon-reload
sudo systemctl start k3s

echo "Waiting for k3s..."
sleep 20

# Step 5: Verify
echo ""
echo "Step 5: Verification..."
echo "=== k3s process ==="
ps aux | grep k3s | grep snapshotter || echo "snapshotter flag not visible in ps"

echo ""
echo "=== k3s status ==="
sudo systemctl status k3s --no-pager | head -5

echo ""
echo "=== Cleanup old pods ==="
kubectl delete pod test-snap --force 2>/dev/null || true
sleep 5

echo ""
echo "=== Create fresh test pod ==="
kubectl run snap-test --image=busybox --restart=Never --command -- sleep 300
sleep 15

echo ""
echo "=== Check new pod's mount type ==="
CONTAINER_ID=$(sudo crictl ps --name snap-test -q | head -1)
echo "Container ID: $CONTAINER_ID"
mount | grep "$CONTAINER_ID" | head -1

echo ""
echo "Done!"

