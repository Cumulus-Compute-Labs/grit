#!/bin/bash
# Unlock CUDA and run full checkpoint test

PID=232300
echo "=== Working with PID: $PID ==="

# First unlock if locked
echo "Current state:"
sudo /usr/local/bin/cuda-checkpoint --get-state --pid $PID 2>&1

echo ""
echo "Unlocking..."
sudo /usr/local/bin/cuda-checkpoint --action unlock --pid $PID 2>&1

echo ""
echo "State after unlock:"
STATE=$(sudo /usr/local/bin/cuda-checkpoint --get-state --pid $PID 2>&1)
echo "$STATE"

# Only proceed if running
if [ "$STATE" = "running" ]; then
    echo ""
    echo "=== Starting Checkpoint Sequence ==="
    
    # Step 1: Lock
    echo "Step 1: Locking CUDA APIs..."
    sudo /usr/local/bin/cuda-checkpoint --action lock --pid $PID 2>&1
    LOCK_RESULT=$?
    echo "Lock result: $LOCK_RESULT"
    sudo /usr/local/bin/cuda-checkpoint --get-state --pid $PID 2>&1
    
    if [ $LOCK_RESULT -eq 0 ]; then
        # Step 2: Checkpoint GPU
        echo ""
        echo "Step 2: Checkpointing GPU state..."
        sudo /usr/local/bin/cuda-checkpoint --action checkpoint --pid $PID 2>&1
        CKPT_RESULT=$?
        echo "Checkpoint result: $CKPT_RESULT"
        sudo /usr/local/bin/cuda-checkpoint --get-state --pid $PID 2>&1
        
        # Step 3: CRIU dump
        echo ""
        echo "Step 3: CRIU dump..."
        sudo rm -rf /tmp/criu-ckpt
        sudo mkdir -p /tmp/criu-ckpt
        
        sudo /usr/local/bin/criu.real dump \
            --pid $PID \
            -D /tmp/criu-ckpt \
            -v4 \
            --shell-job \
            --tcp-established \
            --ext-unix-sk \
            --log-file /tmp/criu-ckpt/dump.log \
            2>&1 | tail -15
        
        CRIU_RESULT=$?
        echo ""
        echo "CRIU result: $CRIU_RESULT"
        
        if [ $CRIU_RESULT -ne 0 ]; then
            echo ""
            echo "=== CRIU Errors ==="
            grep -i -E "error|warn|fail" /tmp/criu-ckpt/dump.log | head -15
        fi
        
        echo ""
        echo "=== Checkpoint Files ==="
        ls -lh /tmp/criu-ckpt/
        
        # Check success
        if [ -f /tmp/criu-ckpt/core-$PID.img ]; then
            echo ""
            echo "✅ SUCCESS: Core image exists!"
        else
            echo ""
            echo "❌ FAILED: No core image"
            echo "Files in checkpoint dir:"
            ls -la /tmp/criu-ckpt/
        fi
    fi
else
    echo "Process not in running state, cannot proceed"
fi

