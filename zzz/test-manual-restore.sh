#!/bin/bash
# Test manual CRIU restore to see if cuda plugin works

set -x

CHECKPOINT_DIR="/mnt/grit-agent/default/gpu-test-ckpt/cuda/checkpoint"
RESTORE_LOG="/tmp/criu-restore-test.log"

echo "=== Step 1: Verify plugin exists ==="
ls -la /usr/lib/criu/cuda_plugin.so

echo ""
echo "=== Step 2: Check checkpoint has cuda data ==="
ls -la "$CHECKPOINT_DIR" | grep -E "cuda|gpu|nvidia" || echo "No cuda-specific files"
ls -la "$CHECKPOINT_DIR"

echo ""
echo "=== Step 3: Check dump.log for cuda plugin during dump ==="
grep -i "cuda\|plugin" "$CHECKPOINT_DIR/dump.log" | tail -20

echo ""
echo "=== Step 4: Try manual CRIU restore with verbose logging ==="
cd /tmp
rm -rf /tmp/restore-test 2>/dev/null
mkdir -p /tmp/restore-test

# Try to restore - this will fail without proper rootfs but will show plugin loading
sudo /usr/local/bin/criu.real restore \
    -D "$CHECKPOINT_DIR" \
    -vvvv \
    --log-file "$RESTORE_LOG" \
    --shell-job \
    2>&1 | head -50 || true

echo ""
echo "=== Step 5: Check restore log for cuda plugin messages ==="
grep -i "cuda\|plugin" "$RESTORE_LOG" 2>/dev/null | head -30 || echo "No cuda/plugin messages in restore log"

echo ""
echo "=== Step 6: Full restore log ==="
cat "$RESTORE_LOG" 2>/dev/null | head -100
