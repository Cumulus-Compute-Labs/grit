#!/bin/bash
# Test CRIU with correct -t flag

PID=232300
CKPT_DIR=/tmp/criu-tree-test

echo "=== Testing CRIU with -t (tree) flag ==="

# Check/fix CUDA state
echo "Current CUDA state:"
STATE=$(sudo /usr/local/bin/cuda-checkpoint --get-state --pid $PID 2>&1)
echo "$STATE"

if [ "$STATE" = "checkpointed" ]; then
    echo "Restoring from checkpointed state..."
    sudo /usr/local/bin/cuda-checkpoint --action restore --pid $PID
    sudo /usr/local/bin/cuda-checkpoint --action unlock --pid $PID
elif [ "$STATE" = "locked" ]; then
    echo "Unlocking..."
    sudo /usr/local/bin/cuda-checkpoint --action unlock --pid $PID
fi

echo ""
echo "State now: $(sudo /usr/local/bin/cuda-checkpoint --get-state --pid $PID)"
echo ""

# Verify process is running
echo "Process status:"
ps -p $PID -o pid,state,comm | head -2
echo ""

# Step 1: Lock CUDA
echo "=== Step 1: Lock CUDA ==="
sudo /usr/local/bin/cuda-checkpoint --action lock --pid $PID
echo "State: $(sudo /usr/local/bin/cuda-checkpoint --get-state --pid $PID)"
echo ""

# Step 2: Checkpoint GPU
echo "=== Step 2: Checkpoint GPU ==="
sudo /usr/local/bin/cuda-checkpoint --action checkpoint --pid $PID
echo "State: $(sudo /usr/local/bin/cuda-checkpoint --get-state --pid $PID)"
echo ""

# Step 3: CRIU dump with -t flag (THE FIX!)
echo "=== Step 3: CRIU Dump with -t flag ==="
sudo rm -rf $CKPT_DIR
sudo mkdir -p $CKPT_DIR

echo "Running: sudo criu dump -t $PID -D $CKPT_DIR -v4 --shell-job --tcp-established --ext-unix-sk"
sudo /usr/local/bin/criu.real dump \
    -t $PID \
    -D $CKPT_DIR \
    -v4 \
    --shell-job \
    --tcp-established \
    --ext-unix-sk \
    --log-file $CKPT_DIR/dump.log

RESULT=$?
echo ""
echo "CRIU exit code: $RESULT"
echo ""

# Results
echo "=== Results ==="
sudo ls -lh $CKPT_DIR/ | head -15

if sudo test -f $CKPT_DIR/core-$PID.img; then
    echo ""
    echo "✅ SUCCESS! Checkpoint created!"
    echo ""
    echo "Total size:"
    sudo du -sh $CKPT_DIR/
else
    echo ""
    echo "❌ FAILED - checking log..."
    echo ""
    sudo grep -i -E "error|warn" $CKPT_DIR/dump.log | head -20
fi

