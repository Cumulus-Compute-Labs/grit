#!/bin/bash
# Build fixed GRIT agent on the server

set -e

echo "=== Building Fixed GRIT Agent ==="

# Use Go 1.23.4
export PATH=/usr/local/go/bin:$PATH
export GOROOT=/usr/local/go

# Check Go version
go version

# Clone or update GRIT repo
GRIT_DIR=/tmp/grit-build
if [ -d "$GRIT_DIR" ]; then
    echo "Removing old build directory..."
    rm -rf "$GRIT_DIR"
fi

echo "Cloning GRIT repo..."
git clone https://github.com/kaito-project/grit.git "$GRIT_DIR"
cd "$GRIT_DIR"

# Copy the fixed runtime.go
echo "Applying GPU checkpoint fix..."
cp /tmp/runtime.go.fixed pkg/gritagent/checkpoint/runtime.go

# Show the diff
echo ""
echo "=== Changes Applied ==="
head -40 pkg/gritagent/checkpoint/runtime.go

# Build
echo ""
echo "=== Building grit-agent ==="
mkdir -p _output
CGO_ENABLED=0 GOOS=linux go build -o _output/grit-agent ./cmd/grit-agent/

if [ -f "_output/grit-agent" ]; then
    echo "✅ Build successful!"
    ls -lh _output/grit-agent
else
    echo "❌ Build failed"
    exit 1
fi

# Copy to system location
echo ""
echo "=== Deploying ==="

# Get current agent image info
CURRENT_IMAGE=$(kubectl get deployment grit-agent -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "none")
echo "Current agent image: $CURRENT_IMAGE"

# For now, just build - we'll need to either:
# 1. Build a Docker image and push
# 2. Or use a simpler deployment method

echo ""
echo "=== Building Docker Image ==="
docker build -t grit-agent:gpu-fix -f docker/grit-agent/Dockerfile .

if [ $? -eq 0 ]; then
    echo "✅ Docker image built: grit-agent:gpu-fix"
else
    echo "❌ Docker build failed, trying alternative method..."
    # Alternative: copy binary to running container
fi

echo ""
echo "=== Deploying Fixed Agent ==="

# Get the current agent pod
AGENT_POD=$(kubectl get pods -n kube-system -l app=grit-agent -o name | head -1)
echo "Current agent pod: $AGENT_POD"

# Update the deployment to use the new image
# For local image, we need to use imagePullPolicy: Never
kubectl patch deployment grit-agent -n kube-system -p '{"spec":{"template":{"spec":{"containers":[{"name":"grit-agent","image":"grit-agent:gpu-fix","imagePullPolicy":"Never"}]}}}}'

echo ""
echo "Waiting for rollout..."
kubectl rollout status deployment/grit-agent -n kube-system --timeout=120s || true

echo ""
echo "=== Deployment Status ==="
kubectl get pods -n kube-system -l app=grit-agent
kubectl logs -n kube-system -l app=grit-agent --tail=10

echo ""
echo "=== Build Complete ==="
