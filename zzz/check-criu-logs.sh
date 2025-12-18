#!/bin/bash
# Check CRIU logs

echo "=== Log files in checkpoint dir ==="
ls -la /mnt/grit-agent/default/gpu-test-ckpt/cuda/checkpoint/*.log 2>/dev/null || echo "No logs"

echo ""
echo "=== restore.log (if exists) ==="
cat /mnt/grit-agent/default/gpu-test-ckpt/cuda/checkpoint/restore.log 2>/dev/null | tail -100 || echo "No restore.log"

echo ""
echo "=== dump.log (last 50 lines) ==="
cat /mnt/grit-agent/default/gpu-test-ckpt/cuda/checkpoint/dump.log 2>/dev/null | tail -50 || echo "No dump.log"

echo ""
echo "=== Check /tmp for any restore logs ==="
find /tmp -name "*restore*.log" -mmin -30 2>/dev/null | head -5

echo ""
echo "=== Check runc working dir ==="
find /run/containerd -name "restore*.log" 2>/dev/null | head -5
