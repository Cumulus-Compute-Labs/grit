#!/bin/bash
# Build shim only

cd /tmp/grit-shim-update
export PATH=/usr/local/go/bin:$PATH

echo "=== Check directory structure ==="
ls -la
ls -la cmd/

echo ""
echo "=== Build ==="
go build -o containerd-shim-grit-v1 -tags "urfave_cli_no_docs no_grpc" ./cmd/containerd-shim-grit-v1

echo ""
echo "=== Check result ==="
if [ -f containerd-shim-grit-v1 ]; then
    ls -la containerd-shim-grit-v1
    echo "Build succeeded!"
    
    echo ""
    echo "=== Deploy ==="
    sudo cp containerd-shim-grit-v1 /usr/local/bin/
    sudo chmod +x /usr/local/bin/containerd-shim-grit-v1
    
    echo ""
    echo "=== Restart containerd ==="
    sudo systemctl restart containerd
    sleep 3
    echo "Done!"
else
    echo "Build failed!"
fi
