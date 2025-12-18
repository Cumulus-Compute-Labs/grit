#!/bin/bash
# Check if cuda-checkpoint restore is being called

echo "=== Check for restore.log in checkpoint dir ==="
ls -la /mnt/grit-agent/default/gpu-test-ckpt/cuda/checkpoint/*.log 2>/dev/null

echo ""
echo "=== Check for any restore logs anywhere ==="
sudo find /tmp -name "*restore*.log" -mmin -10 2>/dev/null | head -5
sudo find /run/containerd -name "restore*.log" -mmin -10 2>/dev/null | head -5
sudo find /var -name "*restore*.log" -mmin -10 2>/dev/null | head -5

echo ""
echo "=== Check CRIU's config file ==="
cat /etc/criu/runc.conf

echo ""
echo "=== Check if cuda-checkpoint is available ==="
which cuda-checkpoint
ls -la /usr/local/cuda/bin/cuda-checkpoint 2>/dev/null

echo ""
echo "=== Check CRIU plugins ==="
ls -la /usr/lib*/criu/plugins/ 2>/dev/null
ls -la /usr/local/lib/criu/plugins/ 2>/dev/null

echo ""
echo "=== Most recent containerd logs related to cuda ==="
sudo journalctl -u containerd --since "5 minutes ago" 2>&1 | grep -i cuda | tail -10

echo ""
echo "=== Check what happens when we try manual CRIU restore ==="
CHECKPOINT_DIR="/mnt/grit-agent/default/gpu-test-ckpt/cuda/checkpoint"
echo "Checkpoint dir: $CHECKPOINT_DIR"
ls -la "$CHECKPOINT_DIR" | head -10
