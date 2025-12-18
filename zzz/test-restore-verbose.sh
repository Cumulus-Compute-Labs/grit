#!/bin/bash
# Test CRIU restore with verbose logging to see cuda plugin

set -x

CHECKPOINT_DIR="/mnt/grit-agent/default/gpu-test-ckpt/cuda/checkpoint"
RESTORE_LOG="/tmp/criu-restore-verbose.log"

echo "=== Try manual CRIU restore ==="
# Need to use --root to point to a rootfs
# For testing, just see if plugin loads

cd /tmp
rm -rf /tmp/restore-work
mkdir -p /tmp/restore-work

# Try restore with pidfile to capture PID
sudo /usr/local/bin/criu.real restore \
    -D "$CHECKPOINT_DIR" \
    -W /tmp/restore-work \
    -vvvv \
    --log-file "$RESTORE_LOG" \
    --shell-job \
    --tcp-established \
    --ext-unix-sk \
    --restore-detached \
    --pidfile /tmp/restore-work/pid.txt \
    2>&1 || true

echo ""
echo "=== Check restore log for cuda plugin ==="
grep -i -E "cuda|plugin" "$RESTORE_LOG" | head -30

echo ""
echo "=== Full restore log head ==="
head -100 "$RESTORE_LOG"

echo ""
echo "=== Full restore log tail ==="
tail -100 "$RESTORE_LOG"
