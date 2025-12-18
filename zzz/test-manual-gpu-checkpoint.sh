#!/bin/bash
# Manual GPU Checkpoint Test - Bypasses runc freeze issue
# This manually steps through: cuda-checkpoint → CRIU dump
set -e

CHECKPOINT_NODE="${1:-192.9.150.56}"
SSH_KEY="${SSH_KEY:-~/.ssh/krish_key}"
CHECKPOINT_DIR="/tmp/manual-gpu-ckpt"

log() { echo "[$(date +%H:%M:%S)] $1"; }

# SSH helper
run_ssh() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "ubuntu@$CHECKPOINT_NODE" "$1"
}

log "=== Manual GPU Checkpoint Test (Bypasses runc) ==="
log "Node: $CHECKPOINT_NODE"

# Step 1: Clean up
log "Step 1: Cleanup..."
run_ssh "kubectl delete deployment gpu-manual-test --force 2>/dev/null || true"
run_ssh "kubectl delete pod -l app=gpu-manual-test --force 2>/dev/null || true"
run_ssh "sudo rm -rf $CHECKPOINT_DIR; sudo mkdir -p $CHECKPOINT_DIR"
sleep 3

# Step 2: Deploy GPU workload (using nvidia runtime, NOT grit)
log "Step 2: Deploying GPU workload..."
run_ssh "cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gpu-manual-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gpu-manual-test
  template:
    metadata:
      labels:
        app: gpu-manual-test
    spec:
      runtimeClassName: nvidia
      containers:
      - name: gpu-app
        image: nvcr.io/nvidia/pytorch:23.10-py3
        command: [\"python3\", \"-u\", \"-c\"]
        args:
        - |
          import torch
          import time
          import os
          
          print(f'PID: {os.getpid()}', flush=True)
          print(f'CUDA available: {torch.cuda.is_available()}', flush=True)
          
          # Allocate GPU memory
          tensor = torch.randn(1024*1024, device='cuda')
          expected_sum = float(tensor.sum().cpu())
          print(f'GPU tensor sum: {expected_sum}', flush=True)
          print('READY', flush=True)
          
          step = 0
          while True:
              step += 1
              current_sum = float(tensor.sum().cpu())
              match = 'OK' if abs(current_sum - expected_sum) < 0.001 else 'CORRUPTED'
              print(f'Step {step}: {match} sum={current_sum}', flush=True)
              time.sleep(2)
        resources:
          limits:
            nvidia.com/gpu: \"1\"
      nodeSelector:
        kubernetes.io/hostname: 192-9-150-56
EOF"

# Step 3: Wait for pod and get container info
log "Step 3: Waiting for pod to be ready..."
for i in {1..60}; do
    POD_NAME=$(run_ssh "kubectl get pods -l app=gpu-manual-test -o jsonpath='{.items[0].metadata.name}' 2>/dev/null" || true)
    if [ -n "$POD_NAME" ]; then
        STATUS=$(run_ssh "kubectl get pod $POD_NAME -o jsonpath='{.status.phase}'" 2>/dev/null || true)
        if [ "$STATUS" = "Running" ]; then
            log "Pod $POD_NAME is running"
            break
        fi
    fi
    sleep 2
done

# Wait for CUDA initialization
log "Step 4: Waiting for CUDA initialization..."
for i in {1..30}; do
    LOGS=$(run_ssh "kubectl logs $POD_NAME 2>/dev/null | tail -5" || true)
    if echo "$LOGS" | grep -q "READY"; then
        log "CUDA initialized!"
        echo "$LOGS"
        break
    fi
    sleep 2
done

# Step 5: Get container PID
log "Step 5: Getting container PID..."
CONTAINER_INFO=$(run_ssh "
    CONTAINER_ID=\$(sudo crictl ps --name gpu-app -q | head -1)
    if [ -z \"\$CONTAINER_ID\" ]; then
        echo 'ERROR: Container not found'
        exit 1
    fi
    
    # Get PID from crictl inspect
    PID=\$(sudo crictl inspect \$CONTAINER_ID | grep -m1 '\"pid\":' | grep -oE '[0-9]+')
    echo \"CONTAINER_ID=\$CONTAINER_ID\"
    echo \"PID=\$PID\"
    
    # Verify it's the Python process
    ps -p \$PID -o pid,comm,args | head -5
")
echo "$CONTAINER_INFO"

PID=$(echo "$CONTAINER_INFO" | grep "^PID=" | cut -d= -f2)
CONTAINER_ID=$(echo "$CONTAINER_INFO" | grep "^CONTAINER_ID=" | cut -d= -f2)

if [ -z "$PID" ] || [ "$PID" = "0" ]; then
    log "ERROR: Could not get container PID"
    exit 1
fi
log "Container PID: $PID"

# Step 6: MANUAL CUDA CHECKPOINT (while process is RUNNING!)
log "Step 6: Calling cuda-checkpoint --action lock (process still running)..."
run_ssh "
    echo 'Before lock - process state:'
    ps -p $PID -o pid,state,comm
    
    echo 'Calling cuda-checkpoint lock...'
    sudo /usr/local/cuda/bin/cuda-checkpoint --pid $PID --action lock 2>&1 || {
        echo 'Lock failed, trying toggle instead...'
        sudo /usr/local/cuda/bin/cuda-checkpoint --pid $PID --action toggle 2>&1 || true
    }
    
    echo 'After lock - process state:'
    ps -p $PID -o pid,state,comm
"

log "Step 7: Calling cuda-checkpoint --action checkpoint..."
run_ssh "
    sudo mkdir -p $CHECKPOINT_DIR/cuda
    sudo /usr/local/cuda/bin/cuda-checkpoint --pid $PID --action checkpoint 2>&1 || echo 'Checkpoint action result: \$?'
    
    echo 'Process state after GPU checkpoint:'
    ps -p $PID -o pid,state,comm
    
    # Check if any CUDA checkpoint files were created
    echo 'CUDA checkpoint files:'
    ls -la $CHECKPOINT_DIR/cuda/ 2>/dev/null || echo 'No cuda dir'
"

# Step 8: Now call CRIU dump directly (NOT through runc)
log "Step 8: Calling CRIU dump directly (bypassing runc freeze)..."
run_ssh "
    sudo mkdir -p $CHECKPOINT_DIR/criu
    
    echo 'Dumping with CRIU (no cgroup freeze, using ptrace)...'
    
    # Call CRIU directly - it will use ptrace to stop the process
    # The --shell-job flag is needed for processes attached to a terminal
    sudo /usr/local/bin/criu.real dump \\
        --pid $PID \\
        -D $CHECKPOINT_DIR/criu \\
        -v4 \\
        --shell-job \\
        --tcp-established \\
        --ext-unix-sk \\
        --log-file $CHECKPOINT_DIR/criu-dump.log \\
        2>&1 | tail -20
    
    RESULT=\$?
    echo \"CRIU dump exit code: \$RESULT\"
    
    echo 'Checkpoint files:'
    ls -la $CHECKPOINT_DIR/criu/ | head -20
    
    if [ \$RESULT -ne 0 ]; then
        echo '=== CRIU dump log (errors) ==='
        grep -i error $CHECKPOINT_DIR/criu-dump.log | head -20
    fi
"

log "Step 9: Check results..."
run_ssh "
    echo '=== Checkpoint directory ==='
    du -sh $CHECKPOINT_DIR
    ls -la $CHECKPOINT_DIR/
    
    echo '=== CRIU images ==='
    ls -la $CHECKPOINT_DIR/criu/ 2>/dev/null | head -10
    
    # Check if core dump exists (indicates successful dump)
    if [ -f $CHECKPOINT_DIR/criu/core-*.img ]; then
        echo '✅ CRIU core image exists - checkpoint likely succeeded!'
    else
        echo '❌ No core image - checkpoint may have failed'
    fi
"

log "=== Manual GPU Checkpoint Test Complete ==="

