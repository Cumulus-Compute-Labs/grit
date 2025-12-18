#!/bin/bash
# Apply GPU checkpoint fix to GRIT

set -e

echo "=== Applying GPU Checkpoint Fix to GRIT ==="
echo ""

# Check if in GRIT repo
if [ ! -f "pkg/gritagent/checkpoint/runtime.go" ]; then
    echo "❌ Error: Must run from GRIT repository root"
    echo "Current directory: $(pwd)"
    exit 1
fi

echo "✅ Found GRIT repository"

# Backup original file
echo "Backing up original runtime.go..."
cp pkg/gritagent/checkpoint/runtime.go pkg/gritagent/checkpoint/runtime.go.backup

# Apply patch
echo "Applying patch..."
if patch -p1 < gpu-checkpoint.patch; then
    echo "✅ Patch applied successfully"
else
    echo "❌ Patch failed to apply"
    echo "Restoring backup..."
    cp pkg/gritagent/checkpoint/runtime.go.backup pkg/gritagent/checkpoint/runtime.go
    exit 1
fi

# Rebuild
echo ""
echo "=== Rebuilding GRIT Agent ==="
make build-agent

if [ $? -eq 0 ]; then
    echo "✅ Build successful"
else
    echo "❌ Build failed"
    echo "Restoring backup..."
    cp pkg/gritagent/checkpoint/runtime.go.backup pkg/gritagent/checkpoint/runtime.go
    exit 1
fi

# Build Docker image
echo ""
echo "=== Building Docker Image ==="
docker build -t grit-agent:gpu-fix -f cmd/grit-agent/Dockerfile .

if [ $? -eq 0 ]; then
    echo "✅ Docker image built: grit-agent:gpu-fix"
else
    echo "❌ Docker build failed"
    exit 1
fi

echo ""
echo "=== Fix Applied Successfully! ==="
echo ""
echo "Next steps:"
echo "1. Deploy to Kubernetes:"
echo "   kubectl set image deployment/grit-agent grit-agent=grit-agent:gpu-fix -n kube-system"
echo ""
echo "2. Test checkpoint:"
echo "   kubectl apply -f checkpoint-cr.yaml"
echo "   kubectl logs deployment/grit-agent -f -n kube-system"
echo ""
echo "3. Verify checkpoint files:"
echo "   ls -lh /mnt/grit-agent/default/checkpoint-name/*.img"
echo ""
echo "Backup saved at: pkg/gritagent/checkpoint/runtime.go.backup"

