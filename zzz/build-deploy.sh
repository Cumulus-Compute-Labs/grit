#!/bin/bash
# Build and deploy the shim

set -e

echo "=== Check files ==="
cd /tmp/grit-shim-update
ls -la

echo ""
echo "=== Build shim ==="
export PATH=/usr/local/go/bin:$PATH
go version
go build -o containerd-shim-grit-v1 -tags "urfave_cli_no_docs no_grpc" ./cmd/containerd-shim-grit-v1

echo ""
echo "=== Check build ==="
ls -la containerd-shim-grit-v1

echo ""
echo "=== Stop containerd and kill shims ==="
sudo pkill -9 -f "containerd-shim" || true
sleep 2
sudo systemctl stop containerd
sleep 2

echo ""
echo "=== Deploy new shim ==="
sudo rm -f /usr/local/bin/containerd-shim-grit-v1
sudo cp containerd-shim-grit-v1 /usr/local/bin/
sudo chmod +x /usr/local/bin/containerd-shim-grit-v1

echo ""
echo "=== Start containerd ==="
sudo systemctl start containerd
sleep 3
sudo systemctl status containerd | head -5

echo ""
echo "=== Verify deployment ==="
ls -la /usr/local/bin/containerd-shim-grit-v1
