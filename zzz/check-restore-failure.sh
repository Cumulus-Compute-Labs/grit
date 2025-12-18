#!/bin/bash
# Check why restore failed

echo "=== Pod Events ==="
kubectl describe pod -l app=gpu-test | grep -A30 Events

echo ""
echo "=== Pod Logs (previous) ==="
kubectl logs -l app=gpu-test --previous --tail=30 2>/dev/null || echo "No previous logs"

echo ""
echo "=== Containerd Shim Logs ==="
sudo journalctl -u containerd --since "10 minutes ago" 2>&1 | grep -iE "grit|restore|criu|error" | tail -50

echo ""
echo "=== Check containerd-shim-grit logs ==="
sudo journalctl --since "10 minutes ago" 2>&1 | grep -i "containerd-shim-grit" | tail -30

echo ""
echo "=== Check checkpoint files ==="
ls -la /mnt/grit-agent/default/gpu-test-ckpt/ 2>/dev/null | head -20
