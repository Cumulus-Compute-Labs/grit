#!/bin/bash
# Test CRIU - fix ALL nvidia mount propagations

PID=232300
CKPT_DIR=/tmp/criu-all-nvidia-test
HOOK_SCRIPT=/tmp/criu-all-nvidia-hook.sh

echo "=== Testing CRIU with comprehensive nvidia mount fix ==="

# Create the action script that fixes ALL nvidia mounts
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
    
    echo "$(date): Finding all mounts with master relationship..."
    
    # Find ALL mounts that have master_id (slave mounts) - these cause "unreachable sharing"
    # mountinfo format: mount_id parent_id major:minor root mount_point optional_fields - fstype source options
    # We look for "master:" in the optional fields which indicates a slave mount
    
    ALL_SLAVE_MOUNTS=$(awk '{
        # Find the separator "-" to locate optional fields
        for (i=1; i<=NF; i++) {
            if ($i == "-") break;
        }
        # Fields before "-" include optional fields which may contain "master:N"
        for (j=7; j<i; j++) {
            if ($j ~ /^master:/) {
                print $5;  # Print mount point
                break;
            }
        }
    }' "/proc/$PID/mountinfo" 2>/dev/null | sort -u)
    
    if [ -n "$ALL_SLAVE_MOUNTS" ]; then
        echo "$(date): Found slave mounts:"
        echo "$ALL_SLAVE_MOUNTS"
        echo ""
        echo "$(date): Making all private..."
        
        echo "$ALL_SLAVE_MOUNTS" | while read -r mnt_path; do
            echo "$(date): Making private: $mnt_path"
            nsenter -t "$PID" -m -- mount --make-private "$mnt_path" 2>&1 || echo "Failed: $mnt_path"
        done
        
        echo "$(date): Done fixing mount propagation"
    else
        echo "$(date): No slave mounts found"
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

# Check slave mounts before
echo "=== Slave mounts before (mounts with master relationship) ==="
awk '{for(i=1;i<=NF;i++){if($i=="-")break}; for(j=7;j<i;j++){if($j~/^master:/){print $5;break}}}' "/proc/$PID/mountinfo" 2>/dev/null | head -10
echo ""

# Lock and checkpoint GPU
echo "=== Step 1: Lock CUDA ==="
sudo /usr/local/bin/cuda-checkpoint --action lock --pid $PID

echo "=== Step 2: Checkpoint GPU ==="
sudo /usr/local/bin/cuda-checkpoint --action checkpoint --pid $PID
echo "State: $(sudo /usr/local/bin/cuda-checkpoint --get-state --pid $PID)"
echo ""

# CRIU dump
echo "=== Step 3: CRIU Dump ==="
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
cat /tmp/criu-action.log 2>/dev/null | tail -30
echo ""

# Check results
echo "=== Checkpoint Files ==="
sudo ls -lh $CKPT_DIR/ | head -15

if sudo test -f $CKPT_DIR/core-$PID.img; then
    echo ""
    echo "✅ SUCCESS! Checkpoint created!"
    sudo du -sh $CKPT_DIR/
else
    echo ""
    echo "❌ FAILED - checking for remaining errors..."
    sudo grep "unreachable sharing" $CKPT_DIR/dump.log | head -5
fi

