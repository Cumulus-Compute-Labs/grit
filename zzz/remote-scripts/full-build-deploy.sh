#!/bin/bash
# Script to build and deploy the GRIT shim on the remote server
# Place this at /tmp/full-build-deploy.sh on the target node

set -e

echo "=== Create temp directory ==="
BUILD_DIR=$(mktemp -d)
cp -r /tmp/grit-shim-update/* "$BUILD_DIR/"
cd "$BUILD_DIR"

echo "=== Copy files from local ==="
# Files should already be copied via scp

echo "=== Check files ==="
ls -la

echo "=== Build shim ==="
go version
if [ -f go.mod ]; then
    echo "go.mod found"
    go build -o containerd-shim-grit-v1 ./cmd/containerd-shim-grit-v1
else
    echo "ERROR: go.mod not found!"
    exit 1
fi

echo ""
echo "=== Check build ==="
ls -la containerd-shim-grit-v1

echo ""
echo "=== Stop containerd and kill shims ==="
sudo systemctl stop containerd || true
sudo pkill -9 -f "containerd-shim" || true
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
sudo systemctl status containerd --no-pager | head -10

echo ""
echo "=== Verify deployment ==="
ls -la /usr/local/bin/containerd-shim-grit-v1

echo ""
echo "=== Cleanup ==="
rm -rf "$BUILD_DIR"
