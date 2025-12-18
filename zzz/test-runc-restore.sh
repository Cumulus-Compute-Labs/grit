#!/bin/bash
# Test runc restore directly

set -x

CHECKPOINT_DIR="/mnt/grit-agent/default/gpu-test-ckpt/cuda/checkpoint"
WORK_DIR="/tmp/runc-restore-test"
BUNDLE_DIR="/tmp/runc-test-bundle"
CONTAINER_ID="test-restore-$$"

echo "=== Setup ==="
rm -rf $WORK_DIR $BUNDLE_DIR
mkdir -p $WORK_DIR $BUNDLE_DIR/rootfs

# Create minimal OCI bundle
# The rootfs needs to be the same as original - use native snapshotter paths
# For testing, let's get the most recent stopped container

echo ""
echo "=== Check what runc sees ==="
sudo runc list 2>/dev/null || echo "No containers"

echo ""
echo "=== Try runc restore directly ==="
# First check what options runc restore accepts
sudo runc restore --help 2>&1 | head -30

echo ""
echo "=== runc.conf contents ==="
cat /etc/criu/runc.conf

echo ""
echo "=== Verify checkpoint files ==="
ls -la $CHECKPOINT_DIR | head -20

echo ""
echo "=== Attempt restore (will likely fail without proper bundle) ==="
sudo runc restore \
  --image-path "$CHECKPOINT_DIR" \
  --work-path "$WORK_DIR" \
  --bundle "$BUNDLE_DIR" \
  --detach \
  "$CONTAINER_ID" 2>&1 || true

echo ""
echo "=== Check work-path for logs ==="
ls -la $WORK_DIR/ 2>/dev/null || echo "No work dir created"
cat $WORK_DIR/restore.log 2>/dev/null | tail -50 || echo "No restore.log"

# Cleanup
sudo runc delete "$CONTAINER_ID" 2>/dev/null || true
