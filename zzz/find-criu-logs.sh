#!/bin/bash
# Find CRIU logs

echo "=== Find any recent CRIU/restore logs ==="
sudo find /run /tmp /mnt -name "*.log" -mmin -10 2>/dev/null | xargs ls -la 2>/dev/null | grep -iE "criu|restore|dump"

echo ""
echo "=== Check checkpoint dir for any logs ==="
sudo ls -la /mnt/grit-agent/default/gpu-test-ckpt/cuda/checkpoint/*.log 2>/dev/null || echo "No logs in checkpoint dir"

echo ""
echo "=== Check the latest bundle ==="
BUNDLE=$(ls -td /run/containerd/io.containerd.runtime.v2.task/k8s.io/*/ 2>/dev/null | head -1)
echo "Latest bundle: $BUNDLE"
if [ -n "$BUNDLE" ]; then
    sudo ls -laR "$BUNDLE" 2>/dev/null | head -50
fi

echo ""
echo "=== Check containerd-shim work directory ==="
sudo find /run/containerd -name "work" -type d 2>/dev/null | head -5 | while read dir; do
    echo "Work dir: $dir"
    sudo ls -la "$dir" 2>/dev/null
done

echo ""
echo "=== Check if runc creates logs elsewhere ==="
sudo find /var/log -name "*runc*" -mmin -10 2>/dev/null
sudo find /tmp -name "*runc*" -mmin -10 2>/dev/null
