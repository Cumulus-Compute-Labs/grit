#!/bin/bash
# Check if CRIU is receiving ext-mount-map auto

echo "=== Find latest restore log ==="
# Find the most recent bundle directory
LATEST_BUNDLE=$(ls -td /run/containerd/io.containerd.runtime.v2.task/k8s.io/*/ 2>/dev/null | head -1)
echo "Latest bundle: $LATEST_BUNDLE"

echo ""
echo "=== Check for CRIU work directory ==="
sudo find /run/containerd -name "restore.log" -mmin -5 2>/dev/null | head -5

echo ""
echo "=== Check runc debug output ==="
# Look in runc log
sudo find /var/log -name "*runc*" -mmin -10 2>/dev/null | xargs cat 2>/dev/null | head -50

echo ""
echo "=== Check shim logs ==="
SHIM_LOGS=$(sudo find /run/containerd -name "log.json" -mmin -5 2>/dev/null | head -3)
for log in $SHIM_LOGS; do
    echo "--- $log ---"
    sudo cat "$log" | tail -20
done

echo ""
echo "=== Try manual CRIU restore with verbose to see if ext-mount-map works ==="
CHECKPOINT_DIR="/mnt/grit-agent/default/gpu-test-ckpt/cuda/checkpoint"
sudo /usr/local/bin/criu.real restore \
    -D "$CHECKPOINT_DIR" \
    -vvvv \
    --log-file /tmp/manual-restore.log \
    --shell-job \
    --tcp-established \
    --ext-unix-sk \
    --ext-mount-map auto \
    2>&1 | head -20 || true

echo ""
echo "=== Check manual restore log for ext-mount ==="
sudo grep -i "ext-mount\|external\|mount.*auto" /tmp/manual-restore.log 2>/dev/null | head -20

echo ""
echo "=== Check if mount error still appears ==="
sudo grep -i "autodetected external mount" /tmp/manual-restore.log 2>/dev/null || echo "No autodetected external mount error!"
