#!/bin/bash
# Check dump.log for cuda plugin messages

echo "=== Check dump.log for cuda and plugin messages ==="
sudo grep -i -E "cuda|plugin" /mnt/grit-agent/default/gpu-test-ckpt/cuda/checkpoint/dump.log | head -50

echo ""
echo "=== Check for cuda-checkpoint files in checkpoint dir ==="
ls -la /mnt/grit-agent/default/gpu-test-ckpt/cuda/checkpoint/ | grep -i cuda

echo ""
echo "=== Check pages-6.img size (should contain GPU memory) ==="
ls -lh /mnt/grit-agent/default/gpu-test-ckpt/cuda/checkpoint/pages-6.img
