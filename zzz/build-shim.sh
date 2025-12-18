#!/bin/bash
# Build the GRIT shim on the server

cd /tmp/grit-shim-update
export PATH=$PATH:/usr/local/go/bin

echo "=== Go version ==="
go version

echo ""
echo "=== Building shim ==="
go build -o containerd-shim-grit-v1 -tags "urfave_cli_no_docs no_grpc" ./cmd/containerd-shim-grit-v1

echo ""
echo "=== Check build result ==="
ls -la containerd-shim-grit-v1

echo ""
echo "=== Deploy shim ==="
sudo cp containerd-shim-grit-v1 /usr/local/bin/
sudo chmod +x /usr/local/bin/containerd-shim-grit-v1

echo ""
echo "=== Verify deployment ==="
ls -la /usr/local/bin/containerd-shim-grit-v1

echo ""
echo "=== Restart containerd to pick up new shim ==="
sudo systemctl restart containerd
sleep 3
sudo systemctl status containerd | head -10
