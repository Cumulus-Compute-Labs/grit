#!/bin/bash
echo "=== Sandbox-related logs ==="
sudo journalctl -u containerd --since "5 min ago" | grep -i sandbox | head -20

echo ""
echo "=== Check crit output for containerd sandbox paths ==="
crit decode -i /mnt/grit-agent/default/gpu-test-ckpt/cuda/checkpoint/mountpoints-13.img --pretty 2>/dev/null | grep -i containerd | head -10
