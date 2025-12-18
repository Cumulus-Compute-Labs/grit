#!/bin/bash
# Deploy fixed GRIT agent

echo "=== Deploying Fixed GRIT Agent ==="

# Check current state
echo "Current GRIT pods:"
kubectl get pods -n kube-system | grep grit

echo ""
echo "Docker images:"
sudo docker images | grep grit-agent

# The grit-agent actually runs as a Job spawned by grit-manager
# We need to update the grit-manager configmap or the job template

# First, let's check how grit-agent is configured
echo ""
echo "=== Checking GRIT Agent Config ==="
kubectl get configmap -n kube-system | grep grit || echo "No grit configmap found"

# Check the grit-manager deployment
echo ""
echo "=== GRIT Manager Deployment ==="
kubectl get deployment grit-manager -n kube-system -o yaml | grep -A5 "image:"

# The key is that when grit-manager creates a checkpoint job, it uses a specific image
# We need to update that image reference

# Let's check the grit-agent-config configmap
echo ""
echo "=== GRIT Agent Config ==="
kubectl get configmap grit-agent-config -n kube-system -o yaml 2>/dev/null || echo "No grit-agent-config configmap"

# Update the configmap to use our new image
echo ""
echo "=== Updating Agent Image ==="

# Get current image from the configmap or use default
CURRENT_IMAGE=$(kubectl get configmap grit-agent-config -n kube-system -o jsonpath='{.data.image}' 2>/dev/null || echo "")
echo "Current agent image: $CURRENT_IMAGE"

# Try to patch the configmap
if kubectl get configmap grit-agent-config -n kube-system &>/dev/null; then
    kubectl patch configmap grit-agent-config -n kube-system -p '{"data":{"image":"grit-agent:gpu-fix"}}'
    echo "✅ ConfigMap updated"
else
    echo "Creating grit-agent-config configmap..."
    kubectl create configmap grit-agent-config -n kube-system --from-literal=image=grit-agent:gpu-fix
fi

# Restart grit-manager to pick up changes
echo ""
echo "=== Restarting GRIT Manager ==="
kubectl rollout restart deployment/grit-manager -n kube-system
kubectl rollout status deployment/grit-manager -n kube-system --timeout=60s || true

echo ""
echo "=== Final Status ==="
kubectl get pods -n kube-system | grep grit

echo ""
echo "✅ Fixed agent deployed! Test with:"
echo "  kubectl apply -f checkpoint-cr.yaml"
