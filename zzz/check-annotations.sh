#!/bin/bash
echo "=== Pod annotations ==="
kubectl get pods -l app=gpu-test -o jsonpath='{.items[0].metadata.annotations}' 2>/dev/null | jq . || echo "No pods found"

echo ""
echo "=== Check a bundle config.json for annotations ==="
# Find a recent bundle
BUNDLE=$(ls -td /run/containerd/io.containerd.runtime.v2.task/k8s.io/*/config.json 2>/dev/null | head -1)
if [ -n "$BUNDLE" ]; then
    echo "Bundle: $BUNDLE"
    jq '.annotations | to_entries[] | select(.key | contains("kubernetes"))' "$BUNDLE" 2>/dev/null | head -20
else
    echo "No bundle found"
fi

echo ""
echo "=== Check NEW pod UID ==="
# Get current pods
kubectl get pods -l app=gpu-test -o jsonpath='{range .items[*]}{.metadata.name}: {.metadata.uid}{"\n"}{end}'
