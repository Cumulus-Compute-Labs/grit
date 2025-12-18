#!/bin/bash
# Check CRIU restore logs

echo "=== Log files in checkpoint dir ==="
ls -la /mnt/grit-agent/default/gpu-test-ckpt/cuda/checkpoint/*.log 2>/dev/null || echo "No log files found"

echo ""
echo "=== dump.log (last 50 lines) ==="
tail -50 /mnt/grit-agent/default/gpu-test-ckpt/cuda/checkpoint/dump.log 2>/dev/null || echo "No dump.log"

echo ""
echo "=== restore.log ==="
cat /mnt/grit-agent/default/gpu-test-ckpt/cuda/checkpoint/restore.log 2>/dev/null || echo "No restore.log"

echo ""
echo "=== Check if there's a criu-restore log elsewhere ==="
find /tmp -name "*restore*log*" 2>/dev/null | head -5
find /var/log -name "*criu*" 2>/dev/null | head -5

echo ""
echo "=== Recent dmesg for CRIU errors ==="
sudo dmesg | grep -i criu | tail -10 2>/dev/null || echo "No CRIU messages in dmesg"
