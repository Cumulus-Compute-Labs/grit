#!/bin/bash
# Check restore result

echo "=== Pod events ==="
kubectl describe pod -l app=gpu-test | grep -A30 Events

echo ""
echo "=== Containerd logs for restore ==="
sudo journalctl -u containerd --since "5 minutes ago" 2>&1 | grep -iE "restore|criu|grit" | tail -40

echo ""
echo "=== Pod logs ==="
kubectl logs -l app=gpu-test --tail=30 2>/dev/null || echo "No logs"

echo ""
echo "=== Grit shim logs ==="
sudo journalctl --since "5 minutes ago" 2>&1 | grep -i "shim" | tail -20

echo ""
echo "=== Check if criu restore was called ==="
sudo journalctl -u containerd --since "5 minutes ago" 2>&1 | grep -iE "OCI runtime restore|checkpoint" | tail -20
