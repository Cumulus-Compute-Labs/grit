#!/bin/bash
# Fix shim to use full paths

cd /tmp/shim-build/grit-src

# Update the code to use full paths and capture stderr
sed -i 's|cmd := exec.Command("nsenter", criuArgs...)|cmd := exec.Command("/usr/bin/nsenter", criuArgs...)|' cmd/containerd-shim-grit-v1/process/init_state.go

# Also add stderr capture
sed -i 's|output, err := cmd.CombinedOutput()|var stderr bytes.Buffer\n\tcmd.Stderr = \&stderr\n\toutput, err := cmd.CombinedOutput()|' cmd/containerd-shim-grit-v1/process/init_state.go

# Add bytes import
sed -i 's|"os/exec"|"bytes"\n\t"os/exec"|' cmd/containerd-shim-grit-v1/process/init_state.go

# Fix the error message to include stderr
sed -i 's|log.G(ctx).Errorf("GPU restore: CRIU failed: %v, output: %s", err, string(output))|log.G(ctx).Errorf("GPU restore: CRIU failed: %v, output: %s, stderr: %s", err, string(output), stderr.String())|' cmd/containerd-shim-grit-v1/process/init_state.go

# Rebuild
export PATH=/usr/local/go/bin:$PATH
export GOROOT=/usr/local/go

echo "=== Rebuilding shim ==="
go build -o /tmp/shim-build/containerd-shim-grit-v1 ./cmd/containerd-shim-grit-v1

if [ -f /tmp/shim-build/containerd-shim-grit-v1 ]; then
    echo "=== Deploying ==="
    sudo systemctl stop k3s
    sleep 2
    sudo pkill -9 -f "containerd-shim-grit" || true
    sleep 2
    sudo rm -f /usr/local/bin/containerd-shim-grit-v1
    sudo cp /tmp/shim-build/containerd-shim-grit-v1 /usr/local/bin/
    sudo chmod +x /usr/local/bin/containerd-shim-grit-v1
    sudo systemctl start k3s
    sleep 10
    echo "Done!"
else
    echo "Build failed"
fi
