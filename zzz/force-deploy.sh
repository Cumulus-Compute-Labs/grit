#!/bin/bash
# Force deploy the new shim

echo "=== Check what holds the file ==="
sudo lsof /usr/local/bin/containerd-shim-grit-v1 2>/dev/null || echo "No lsof results"

echo ""
echo "=== List shim processes ==="
ps aux | grep -E "shim|containerd" | grep -v grep

echo ""
echo "=== Kill all shim processes ==="
sudo pkill -9 -f "containerd-shim"
sleep 2

echo ""
echo "=== Stop containerd ==="
sudo systemctl stop containerd
sleep 2

echo ""
echo "=== Remove old binary ==="
sudo rm -f /usr/local/bin/containerd-shim-grit-v1

echo ""
echo "=== Copy new binary ==="
sudo cp /tmp/grit-shim-update/containerd-shim-grit-v1 /usr/local/bin/
sudo chmod +x /usr/local/bin/containerd-shim-grit-v1

echo ""
echo "=== Verify ==="
ls -la /usr/local/bin/containerd-shim-grit-v1

echo ""
echo "=== Start containerd ==="
sudo systemctl start containerd
sleep 3

echo ""
echo "=== Check status ==="
sudo systemctl status containerd | head -5
