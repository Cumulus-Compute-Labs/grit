#!/bin/bash
# Test CRIU with action script to fix mount propagation

PID=232300
CKPT_DIR=/tmp/criu-hook-test
HOOK_SCRIPT=/tmp/criu-hook.sh

echo "=== Testing CRIU with pre-dump hook ==="

# Create the action script
cat > $HOOK_SCRIPT << 'HOOK_EOF'
#!/bin/bash
exec >> /tmp/criu-action.log 2>&1
echo "$(date): Action=$CRTOOLS_SCRIPT_ACTION PID=$CRTOOLS_INIT_PID"

if [ "$CRTOOLS_SCRIPT_ACTION" == "pre-dump" ]; then
    PID="$CRTOOLS_INIT_PID"
    
    if [ -z "$PID" ]; then
        echo "$(date): ERROR - CRTOOLS_INIT_PID is empty"
        exit 0
    fi
    
    echo "$(date): Changing GPU mount propagation to private..."
    
    # Find GPU mounts with master relationship
    GPU_MOUNTS=$(awk '$5 ~ /\/proc\/driver\/nvidia\/gpus\// {print $5}' "/proc/$PID/mountinfo" 2>/dev/null | sort -u)
    
    if [ -n "$GPU_MOUNTS" ]; then
        echo "$GPU_MOUNTS" | while read -r mnt_path; do
            echo "$(date): Making private: $mnt_path"
            nsenter -t "$PID" -m -- mount --make-private "$mnt_path" 2>&1 || true
        done
    fi
fi
exit 0
HOOK_EOF
chmod +x $HOOK_SCRIPT

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

# Clear previous action log
rm -f /tmp/criu-action.log

# Lock and checkpoint GPU
echo "=== Step 1: Lock CUDA ==="
sudo /usr/local/bin/cuda-checkpoint --action lock --pid $PID
echo "State: $(sudo /usr/local/bin/cuda-checkpoint --get-state --pid $PID)"

echo "=== Step 2: Checkpoint GPU ==="
sudo /usr/local/bin/cuda-checkpoint --action checkpoint --pid $PID
echo "State: $(sudo /usr/local/bin/cuda-checkpoint --get-state --pid $PID)"
echo ""

# CRIU dump with action script
echo "=== Step 3: CRIU Dump with action-script ==="
sudo rm -rf $CKPT_DIR
sudo mkdir -p $CKPT_DIR

sudo /usr/local/bin/criu.real dump \
    -t $PID \
    -D $CKPT_DIR \
    -v4 \
    --shell-job \
    --tcp-established \
    --ext-unix-sk \
    --action-script $HOOK_SCRIPT \
    --log-file $CKPT_DIR/dump.log

RESULT=$?
echo "CRIU exit code: $RESULT"
echo ""

# Show action script log
echo "=== Action Script Log ==="
cat /tmp/criu-action.log 2>/dev/null || echo "No action log"
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
    echo "Errors from log:"
    sudo grep -i error $CKPT_DIR/dump.log | tail -10
fi

