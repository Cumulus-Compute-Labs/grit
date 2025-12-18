#!/bin/bash
# Check final restore status

echo "=== Restore log ==="
cat /mnt/grit-agent/default/gpu-test-ckpt/cuda/checkpoint/restore.log 2>/dev/null | tail -100 || echo "No restore log"

echo ""
echo "=== Pod events ==="
kubectl describe pod -l app=gpu-test | grep -A20 Events

echo ""
echo "=== Containerd logs for restore ==="
sudo journalctl -u containerd --since "5 minutes ago" 2>&1 | grep -iE "GPU restore|criu|restore" | tail -30

echo ""
echo "=== Check shim logs ==="
sudo journalctl --since "5 minutes ago" 2>&1 | grep -i "shim" | grep -v "cleaning" | tail -20
