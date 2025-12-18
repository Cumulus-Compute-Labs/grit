#!/bin/bash
# FINAL TEST with --force-irmap for fsnotify/overlayfs fix

PID=232300
CKPT_DIR=/tmp/criu-irmap-test
HOOK_SCRIPT=/tmp/criu-fix-mounts.sh

echo "=== FINAL TEST: --external 'mnt[]' + --force-irmap ==="

# Create action script to fix mount propagation
cat > $HOOK_SCRIPT << 'HOOK_EOF'
#!/bin/bash
exec >> /tmp/criu-action.log 2>&1
echo "$(date): Action=$CRTOOLS_SCRIPT_ACTION PID=$CRTOOLS_INIT_PID"
if [ "$CRTOOLS_SCRIPT_ACTION" == "pre-dump" ]; then
    PID="$CRTOOLS_INIT_PID"
    [ -z "$PID" ] && exit 0
    ALL_SLAVE_MOUNTS=$(awk '{for(i=1;i<=NF;i++){if($i=="-")break}for(j=7;j<i;j++){if($j~/^master:/){print $5;break}}}' "/proc/$PID/mountinfo" 2>/dev/null | sort -u)
    [ -n "$ALL_SLAVE_MOUNTS" ] && echo "$ALL_SLAVE_MOUNTS" | while read -r mnt; do
        nsenter -t "$PID" -m -- mount --make-private "$mnt" 2>/dev/null || true
    done
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

# Verify process
echo "=== Process Status ==="
ps -p $PID -o pid,state,comm | head -2
kubectl logs -l app=gpu-manual-test --tail=2 2>/dev/null || true
echo ""

# Clear logs
sudo rm -f /tmp/criu-action.log 2>/dev/null || true

# Lock and checkpoint GPU
echo "=== Step 1: Lock CUDA ==="
sudo /usr/local/bin/cuda-checkpoint --action lock --pid $PID
echo "State: $(sudo /usr/local/bin/cuda-checkpoint --get-state --pid $PID)"

echo "=== Step 2: Checkpoint GPU ==="
sudo /usr/local/bin/cuda-checkpoint --action checkpoint --pid $PID
echo "State: $(sudo /usr/local/bin/cuda-checkpoint --get-state --pid $PID)"
echo ""

# CRIU dump with --external 'mnt[]' AND --force-irmap
echo "=== Step 3: CRIU Dump ==="
sudo rm -rf $CKPT_DIR
sudo mkdir -p $CKPT_DIR

echo "Flags: --external 'mnt[]' --force-irmap"
echo ""

sudo /usr/local/bin/criu.real dump \
    -t $PID \
    -D $CKPT_DIR \
    -v4 \
    --external 'mnt[]' \
    --force-irmap \
    --shell-job \
    --tcp-established \
    --ext-unix-sk \
    --action-script $HOOK_SCRIPT \
    --log-file $CKPT_DIR/dump.log

RESULT=$?
echo ""
echo "CRIU exit code: $RESULT"
echo ""

# Check results
echo "=== Checkpoint Files ==="
sudo ls -lh $CKPT_DIR/ | head -25

if sudo test -f $CKPT_DIR/core-$PID.img; then
    echo ""
    echo "🎉🎉🎉 SUCCESS! GPU CHECKPOINT CREATED! 🎉🎉🎉"
    echo ""
    echo "Total checkpoint size:"
    sudo du -sh $CKPT_DIR/
    echo ""
    echo "Core and memory images:"
    sudo ls -lh $CKPT_DIR/core*.img $CKPT_DIR/pages*.img 2>/dev/null
else
    echo ""
    echo "❌ FAILED"
    echo ""
    echo "Last errors:"
    sudo grep -i error $CKPT_DIR/dump.log | tail -10
fi

