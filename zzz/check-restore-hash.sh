#!/bin/bash
# Check restore hash matching

echo "=== Checkpoint Info ==="
kubectl get checkpoint gpu-test-ckpt -o yaml | grep -E "podSpecHash|podName"

echo ""
echo "=== Original Checkpointed Pod Name ==="
ORIG_POD=$(kubectl get checkpoint gpu-test-ckpt -o jsonpath='{.spec.podName}')
echo "Original pod: $ORIG_POD"

echo ""
echo "=== Current Pods ==="
kubectl get pods -l app=gpu-test

echo ""
echo "=== Restore Status ==="
kubectl get restore gpu-test-restore -o yaml | grep -A20 "status:"
