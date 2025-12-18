#!/bin/bash
# Full build and deploy - run from Windows via scp

set -e

DEST=/tmp/grit-build-$$

echo "=== Create temp directory ==="
mkdir -p $DEST

echo "=== Copy files from local ==="
# Files already copied to /tmp/grit-shim-update by scp
cp -r /tmp/grit-shim-update/* $DEST/ 2>/dev/null || true

echo "=== Check files ==="
ls -la $DEST/

echo ""
echo "=== Build shim ==="
cd $DEST
export PATH=/usr/local/go/bin:$PATH
go version

if [ -f go.mod ]; then
    echo "go.mod found"
    go build -o containerd-shim-grit-v1 -tags "urfave_cli_no_docs no_grpc" ./cmd/containerd-shim-grit-v1
else
    echo "ERROR: go.mod not found!"
    ls -la
    exit 1
fi

echo ""
echo "=== Check build ==="
ls -la containerd-shim-grit-v1

echo ""
echo "=== Stop containerd and kill shims ==="
sudo pkill -9 -f "containerd-shim" || true
sleep 2
sudo systemctl stop containerd || true
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

echo ""
echo "=== Cleanup ==="
rm -rf $DEST
