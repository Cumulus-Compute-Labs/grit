#!/bin/bash
# Deploy new shim

echo "=== Find processes using shim ==="
sudo lsof /usr/local/bin/containerd-shim-grit-v1 2>/dev/null | head -10 || echo "No processes found"

echo ""
echo "=== Stop k3s entirely ==="
sudo systemctl stop k3s

echo ""
echo "=== Wait and check again ==="
sleep 5
sudo lsof /usr/local/bin/containerd-shim-grit-v1 2>/dev/null | head -10 || echo "No processes using shim now"

echo ""
echo "=== Copy new shim ==="
sudo cp /tmp/shim-build/containerd-shim-grit-v1 /usr/local/bin/containerd-shim-grit-v1
sudo chmod +x /usr/local/bin/containerd-shim-grit-v1

echo ""
echo "=== Verify new shim ==="
ls -la /usr/local/bin/containerd-shim-grit*
md5sum /usr/local/bin/containerd-shim-grit-v1
md5sum /tmp/shim-build/containerd-shim-grit-v1

echo ""
echo "=== Start k3s ==="
sudo systemctl start k3s
sleep 15

echo ""
echo "=== Verify cluster ==="
kubectl get nodes
kubectl get pods -A | head -10
