#!/bin/bash
# Install newer Go and build shim

echo "=== Install Go 1.23 ==="
cd /tmp
wget -q https://go.dev/dl/go1.23.4.linux-amd64.tar.gz
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf go1.23.4.linux-amd64.tar.gz
export PATH=/usr/local/go/bin:$PATH

echo ""
echo "=== Verify Go ==="
go version

echo ""
echo "=== Build shim ==="
cd /tmp/grit-shim-update
go build -o containerd-shim-grit-v1 -tags "urfave_cli_no_docs no_grpc" ./cmd/containerd-shim-grit-v1

if [ -f containerd-shim-grit-v1 ]; then
    echo ""
    echo "=== Deploy shim ==="
    sudo cp containerd-shim-grit-v1 /usr/local/bin/
    sudo chmod +x /usr/local/bin/containerd-shim-grit-v1
    ls -la /usr/local/bin/containerd-shim-grit-v1
    
    echo ""
    echo "=== Restart containerd ==="
    sudo systemctl restart containerd
    sleep 3
    sudo systemctl status containerd | head -5
else
    echo "Build failed!"
fi
