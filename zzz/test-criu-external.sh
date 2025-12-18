#!/bin/bash
# Test CRIU with -t and --enable-external-masters

PID=232300
CKPT_DIR=/tmp/criu-external-test

echo "=== Testing CRIU with --enable-external-masters ==="

# Reset CUDA state
STATE=$(sudo /usr/local/bin/cuda-checkpoint --get-state --pid $PID 2>&1)
echo "Current state: $STATE"
if [ "$STATE" = "checkpointed" ]; then
    sudo /usr/local/bin/cuda-checkpoint --action restore --pid $PID
    sudo /usr/local/bin/cuda-checkpoint --action unlock --pid $PID
elif [ "$STATE" = "locked" ]; then
    sudo /usr/local/bin/cuda-checkpoint --action unlock --pid $PID
fi
echo "State now: $(sudo /usr/local/bin/cuda-checkpoint --get-state --pid $PID)"
echo ""

# Lock and checkpoint GPU
echo "=== Locking CUDA ==="
sudo /usr/local/bin/cuda-checkpoint --action lock --pid $PID
echo "=== Checkpointing GPU ==="
sudo /usr/local/bin/cuda-checkpoint --action checkpoint --pid $PID
echo "State: $(sudo /usr/local/bin/cuda-checkpoint --get-state --pid $PID)"
echo ""

# CRIU dump with external-masters
echo "=== CRIU Dump with --enable-external-masters ==="
sudo rm -rf $CKPT_DIR
sudo mkdir -p $CKPT_DIR

sudo /usr/local/bin/criu.real dump \
    -t $PID \
    -D $CKPT_DIR \
    -v4 \
    --shell-job \
    --tcp-established \
    --ext-unix-sk \
    --enable-external-masters \
    --enable-external-sharing \
    --log-file $CKPT_DIR/dump.log

RESULT=$?
echo "CRIU exit code: $RESULT"
echo ""

# Check results
echo "=== Checkpoint Files ==="
sudo ls -lh $CKPT_DIR/ | head -15

if sudo test -f $CKPT_DIR/core-$PID.img; then
    echo ""
    echo "✅ SUCCESS! Core image created!"
    sudo du -sh $CKPT_DIR/
else
    echo ""
    echo "❌ FAILED"
    echo "Last 20 lines of log:"
    sudo tail -20 $CKPT_DIR/dump.log
fi

