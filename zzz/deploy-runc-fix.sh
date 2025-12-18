#!/bin/bash
# Deploy the runc direct-call fix

set -e

echo "=== Copy source files ==="
rm -rf /tmp/grit-shim-update
mkdir -p /tmp/grit-shim-update/cmd

# These will be copied by scp from Windows side

echo "=== Build shim ==="
cd /tmp/grit-shim-update
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
