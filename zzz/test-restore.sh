#!/bin/bash
# Test CRIU restore

CKPT_DIR="/tmp/criu-final-nfs-test"

echo "=== Testing CRIU Restore ==="

# Kill any existing python process from the checkpoint
echo "Step 1: Killing original process..."
ORIG_PID=$(pgrep -f "python3 -u -c" | head -1)
if [ -n "$ORIG_PID" ]; then
    echo "Found process $ORIG_PID, killing..."
    sudo kill -9 $ORIG_PID 2>/dev/null
    sleep 2
fi

echo ""
echo "Step 2: Verifying process is dead..."
if pgrep -f "python3 -u -c" > /dev/null; then
    echo "WARNING: Process still running!"
else
    echo "Process killed successfully"
fi

echo ""
echo "Step 3: Attempting restore..."
cd $CKPT_DIR

sudo /usr/local/bin/criu.real restore \
    -D . \
    -v4 \
    --log-file restore.log \
    --shell-job \
    --mntns-compat-mode \
    --restore-detached

RESULT=$?
echo ""
echo "Restore exit code: $RESULT"

if [ $RESULT -eq 0 ]; then
    echo ""
    echo "=== SUCCESS! Checking restored process ==="
    sleep 3
    
    NEW_PID=$(pgrep -f "python3 -u -c" | head -1)
    echo "Restored PID: $NEW_PID"
    
    echo ""
    echo "Process info:"
    ps -p $NEW_PID -o pid,ppid,comm,etime 2>/dev/null
    
    echo ""
    echo "Checking GPU memory is intact..."
    # The process should still be running and checking the tensor
    # Look at recent output if available
else
    echo ""
    echo "=== RESTORE FAILED ==="
    echo "Last 30 lines of restore log:"
    sudo tail -30 $CKPT_DIR/restore.log
fi

