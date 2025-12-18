#!/bin/bash
# Manual CUDA checkpoint test - bypasses runc freeze

# Get container PID
CONTAINER_ID=$(sudo crictl ps --name gpu-app -q | head -1)
if [ -z "$CONTAINER_ID" ]; then
    echo "ERROR: Container not found"
    exit 1
fi

PID=$(sudo crictl inspect "$CONTAINER_ID" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['info']['pid'])")
echo "Container ID: $CONTAINER_ID"
echo "Python PID: $PID"
echo ""

# Check process is running
echo "=== Process Status ==="
ps -p "$PID" -o pid,state,comm,args | head -2
echo ""

# Test cuda-checkpoint get-state
echo "=== CUDA Checkpoint State ==="
sudo /usr/local/bin/cuda-checkpoint --get-state --pid "$PID" 2>&1
echo "Exit code: $?"
echo ""

# Step 1: Lock CUDA APIs (process still running!)
echo "=== Step 1: Locking CUDA APIs ==="
sudo /usr/local/bin/cuda-checkpoint --action lock --pid "$PID" 2>&1
LOCK_RESULT=$?
echo "Lock exit code: $LOCK_RESULT"
echo ""

# Check state after lock
echo "=== State After Lock ==="
sudo /usr/local/bin/cuda-checkpoint --get-state --pid "$PID" 2>&1
echo ""

# Check process state after lock
echo "=== Process State After Lock ==="
ps -p "$PID" -o pid,state,comm 2>/dev/null
echo ""

# Step 2: Checkpoint GPU state (no --dir, it stores in process memory)
if [ $LOCK_RESULT -eq 0 ]; then
    echo "=== Step 2: Checkpointing GPU State ==="
    sudo /usr/local/bin/cuda-checkpoint --action checkpoint --pid "$PID" 2>&1
    CKPT_RESULT=$?
    echo "Checkpoint exit code: $CKPT_RESULT"
    echo ""
    
    # Check state after checkpoint
    echo "=== State After GPU Checkpoint ==="
    sudo /usr/local/bin/cuda-checkpoint --get-state --pid "$PID" 2>&1
    echo ""
fi

# Step 3: CRIU dump (with correct PID)
echo "=== Step 3: CRIU Dump (PID=$PID) ==="
sudo rm -rf /tmp/criu-ckpt
sudo mkdir -p /tmp/criu-ckpt

# Note: Not using cgroup freezer, CRIU will use ptrace
sudo /usr/local/bin/criu.real dump \
    --pid "$PID" \
    -D /tmp/criu-ckpt \
    -v4 \
    --shell-job \
    --tcp-established \
    --ext-unix-sk \
    --log-file /tmp/criu-ckpt/dump.log \
    2>&1 | tail -20

CRIU_RESULT=$?
echo ""
echo "CRIU dump exit code: $CRIU_RESULT"
echo ""

if [ $CRIU_RESULT -ne 0 ]; then
    echo "=== CRIU Dump Log (errors) ==="
    sudo grep -i -E "error|warn|fail" /tmp/criu-ckpt/dump.log 2>/dev/null | head -15
fi

echo ""
echo "=== CRIU Checkpoint Files ==="
ls -la /tmp/criu-ckpt/ | head -15

# Check if core image exists
if sudo test -f /tmp/criu-ckpt/core-*.img; then
    echo ""
    echo "✅ SUCCESS: Core image exists!"
    echo "Checkpoint files:"
    ls -lh /tmp/criu-ckpt/*.img | head -10
else
    echo ""
    echo "❌ FAILED: No core image"
fi

