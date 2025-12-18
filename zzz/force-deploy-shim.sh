#!/bin/bash
# Force deploy new shim by killing old processes

echo "=== Stop k3s ==="
sudo systemctl stop k3s

echo ""
echo "=== Kill all containerd-shim-grit processes ==="
sudo pkill -9 -f "containerd-shim-grit" || true
sleep 2

echo ""
echo "=== Check if any processes still using shim ==="
sudo lsof /usr/local/bin/containerd-shim-grit-v1 2>/dev/null || echo "No processes using shim"

echo ""
echo "=== Remove old shim and copy new one ==="
sudo rm -f /usr/local/bin/containerd-shim-grit-v1
sudo cp /tmp/shim-build/containerd-shim-grit-v1 /usr/local/bin/containerd-shim-grit-v1
sudo chmod +x /usr/local/bin/containerd-shim-grit-v1

echo ""
echo "=== Verify ==="
ls -la /usr/local/bin/containerd-shim-grit*
echo ""
echo "MD5 sums:"
md5sum /usr/local/bin/containerd-shim-grit-v1
md5sum /tmp/shim-build/containerd-shim-grit-v1

echo ""
echo "=== Start k3s ==="
sudo systemctl start k3s
sleep 15

echo ""
echo "=== Verify cluster ==="
kubectl get nodes
