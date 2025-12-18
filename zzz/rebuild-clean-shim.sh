#!/bin/bash
# Rebuild a completely clean shim from upstream GRIT

set -e

echo "=== Step 1: Clone fresh GRIT repo ==="
cd /tmp
rm -rf /tmp/clean-shim 2>/dev/null || true
mkdir -p /tmp/clean-shim
cd /tmp/clean-shim

git clone --depth 1 https://github.com/kaito-project/grit.git grit-src
cd grit-src

echo ""
echo "=== Step 2: Verify init_state.go is original (no GPU restore code) ==="
grep -c "GPU restore" cmd/containerd-shim-grit-v1/process/init_state.go 2>/dev/null && echo "WARNING: GPU restore code found!" || echo "OK: No custom GPU restore code"

echo ""
echo "=== Step 3: Build clean shim ==="
export PATH=/usr/local/go/bin:$PATH
export GOROOT=/usr/local/go
go build -o /tmp/clean-shim/containerd-shim-grit-v1 ./cmd/containerd-shim-grit-v1

echo ""
echo "=== Step 4: Stop k3s and kill shims ==="
sudo systemctl stop k3s
sleep 3
sudo pkill -9 -f "containerd-shim-grit" || true
sleep 2

echo ""
echo "=== Step 5: Deploy clean shim ==="
sudo rm -f /usr/local/bin/containerd-shim-grit-v1
sudo rm -f /usr/local/bin/containerd-shim-grit-v1.backup
sudo cp /tmp/clean-shim/containerd-shim-grit-v1 /usr/local/bin/containerd-shim-grit-v1
sudo chmod +x /usr/local/bin/containerd-shim-grit-v1

echo ""
echo "=== Step 6: Verify runc.conf ==="
cat /etc/criu/runc.conf

echo ""
echo "=== Step 7: Start k3s ==="
sudo systemctl start k3s
sleep 15

echo ""
echo "=== Step 8: Verify ==="
ls -la /usr/local/bin/containerd-shim-grit-v1
echo ""
kubectl get nodes

echo ""
echo "=== Done! Clean shim deployed ==="
