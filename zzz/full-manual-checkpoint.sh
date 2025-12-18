#!/bin/bash
# Full manual GPU checkpoint - bypasses runc freeze issue
set -e

PID=232300
CKPT_DIR=/tmp/full-manual-ckpt

echo "=== Full Manual GPU Checkpoint ==="
echo "PID: $PID"
echo ""

# Cleanup
sudo rm -rf $CKPT_DIR
sudo mkdir -p $CKPT_DIR

# Verify process is running
echo "=== Step 0: Verify process ==="
ps -p $PID -o pid,state,comm,args | head -2
sudo /usr/local/bin/cuda-checkpoint --get-state --pid $PID
echo ""

# Step 1: Lock CUDA APIs
echo "=== Step 1: Lock CUDA ==="
sudo /usr/local/bin/cuda-checkpoint --action lock --pid $PID
echo "State: $(sudo /usr/local/bin/cuda-checkpoint --get-state --pid $PID)"
echo ""

# Step 2: Checkpoint GPU state
echo "=== Step 2: Checkpoint GPU ==="
sudo /usr/local/bin/cuda-checkpoint --action checkpoint --pid $PID
echo "State: $(sudo /usr/local/bin/cuda-checkpoint --get-state --pid $PID)"
echo ""

# Step 3: CRIU dump
echo "=== Step 3: CRIU Dump ==="
sudo /usr/local/bin/criu.real dump \
    --pid $PID \
    -D $CKPT_DIR \
    -v4 \
    --shell-job \
    --tcp-established \
    --ext-unix-sk \
    --log-file $CKPT_DIR/dump.log

RESULT=$?
echo "CRIU exit code: $RESULT"
echo ""

# Check results
echo "=== Results ==="
echo "Checkpoint files:"
sudo ls -lh $CKPT_DIR/

if sudo test -f $CKPT_DIR/core-$PID.img; then
    echo ""
    echo "✅ SUCCESS! Core image exists!"
    echo ""
    echo "Image files:"
    sudo ls -lh $CKPT_DIR/*.img | head -10
    echo ""
    echo "Total size:"
    sudo du -sh $CKPT_DIR/
else
    echo ""
    echo "❌ FAILED - No core image"
    echo ""
    echo "=== CRIU Log ==="
    sudo cat $CKPT_DIR/dump.log
fi

