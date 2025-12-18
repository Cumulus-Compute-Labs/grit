#!/bin/bash
# Manual Dump + GRIT Restore Test

set -e

echo "=== Manual Dump + GRIT Restore Test ==="
echo ""

HOSTNAME=$(hostname)
CKPT_DIR=/tmp/criu-manual-checkpoint
GRIT_DIR=/mnt/grit-agent/default/manual-gpu-ckpt

# Step 1: Create GPU pod
echo "=== Step 1: Creating GPU pod ==="
kubectl delete deployment gpu-manual-test --force 2>/dev/null || true
sleep 5

cat <<EOF | kubectl apply -f -
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
      runtimeClassName: grit
      containers:
      - name: gpu-app
        image: pytorch/pytorch:2.1.0-cuda12.1-cudnn8-runtime
        command: ["python3", "-u", "-c"]
        args:
        - |
          import torch
          import time
          import os
          
          print(f'PID: {os.getpid()}', flush=True)
          print(f'CUDA: {torch.cuda.is_available()}', flush=True)
          
          # Create deterministic GPU data
          torch.manual_seed(42424242)
          tensor = torch.randn(1024*1024, device='cuda')
          expected = float(tensor.sum().cpu())
          print(f'Sum: {expected}', flush=True)
          print('READY', flush=True)
          
          step = 0
          while True:
              step += 1
              current = float(tensor.sum().cpu())
              status = 'OK' if abs(current - expected) < 0.001 else 'CORRUPTED'
              print(f'Step {step}: {status} sum={current}', flush=True)
              time.sleep(2)
        resources:
          limits:
            nvidia.com/gpu: "1"
      nodeSelector:
        kubernetes.io/hostname: $HOSTNAME
EOF

echo "Waiting for pod..."
for i in {1..60}; do
    POD=$(kubectl get pods -l app=gpu-manual-test -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$POD" ]; then
        STATUS=$(kubectl get pod $POD -o jsonpath='{.status.phase}' 2>/dev/null)
        if [ "$STATUS" = "Running" ]; then
            echo "Pod $POD is running"
            break
        fi
    fi
    sleep 3
done

# Wait for CUDA init
echo "Waiting for CUDA..."
for i in {1..60}; do
    if kubectl logs $POD 2>/dev/null | grep -q "READY"; then
        echo "CUDA ready!"
        kubectl logs $POD --tail=5
        break
    fi
    sleep 3
done

sleep 5

# Extract expected values
EXPECTED_SUM=$(kubectl logs $POD | grep "Sum:" | awk '{print $2}')
echo "Expected sum: $EXPECTED_SUM"

# Step 2: Manual Checkpoint
echo ""
echo "=== Step 2: Manual Checkpoint ==="

CONTAINER_ID=$(sudo crictl ps | grep gpu-app | awk '{print $1}' | head -1)
echo "Container: $CONTAINER_ID"

PID=$(pgrep -f "python3 -u -c" | head -1)
echo "Python PID: $PID"

# Create action script for mount fix
HOOK_SCRIPT=/tmp/criu-hook.sh
cat > $HOOK_SCRIPT << 'HOOK_EOF'
#!/bin/bash
exec >> /tmp/criu-action.log 2>&1
if [ "$CRTOOLS_SCRIPT_ACTION" == "pre-dump" ]; then
    PID="$CRTOOLS_INIT_PID"
    [ -z "$PID" ] && exit 0
    awk '{for(i=1;i<=NF;i++){if($i=="-")break}for(j=7;j<i;j++){if($j~/^master:/){print $5;break}}}' "/proc/$PID/mountinfo" 2>/dev/null | while read -r mnt; do
        nsenter -t "$PID" -m -- mount --make-private "$mnt" 2>/dev/null || true
    done
fi
exit 0
HOOK_EOF
chmod +x $HOOK_SCRIPT

# CUDA checkpoint
echo "Locking & checkpointing CUDA..."
sudo /usr/local/bin/cuda-checkpoint --action lock --pid $PID
sudo /usr/local/bin/cuda-checkpoint --action checkpoint --pid $PID
echo "CUDA state: $(sudo /usr/local/bin/cuda-checkpoint --get-state --pid $PID)"

# CRIU dump
echo "Running CRIU dump..."
sudo rm -rf $CKPT_DIR
sudo mkdir -p $CKPT_DIR

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
echo "CRIU exit code: $RESULT"

if [ $RESULT -ne 0 ]; then
    echo "FAILED: CRIU dump failed"
    sudo tail -30 $CKPT_DIR/dump.log
    exit 1
fi

echo "✅ Checkpoint created: $(sudo du -sh $CKPT_DIR)"
sudo ls -lh $CKPT_DIR/*.img | head -5

# Step 3: Copy checkpoint to GRIT location
echo ""
echo "=== Step 3: Preparing for GRIT restore ==="

sudo rm -rf $GRIT_DIR
sudo mkdir -p $GRIT_DIR
sudo cp -r $CKPT_DIR/* $GRIT_DIR/
echo "Checkpoint copied to GRIT location"

# Delete original deployment
kubectl delete deployment gpu-manual-test --force
sleep 10

# Step 4: Create GRIT restore pod
echo ""
echo "=== Step 4: Creating GRIT restore pod ==="

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gpu-restored
  annotations:
    grit.dev/checkpoint: "$GRIT_DIR"
    grit.dev/restore-name: "manual-gpu-ckpt"
spec:
  runtimeClassName: grit
  nodeSelector:
    kubernetes.io/hostname: $HOSTNAME
  containers:
  - name: gpu-app
    image: pytorch/pytorch:2.1.0-cuda12.1-cudnn8-runtime
    command: ["python3", "-u", "-c"]
    args:
    - |
      import torch
      import time
      
      torch.manual_seed(42424242)
      tensor = torch.randn(1024*1024, device='cuda')
      expected = float(tensor.sum().cpu())
      
      step = 0
      while True:
          step += 1
          current = float(tensor.sum().cpu())
          status = 'OK' if abs(current - expected) < 0.001 else 'CORRUPTED'
          print(f'Step {step}: {status} sum={current}', flush=True)
          time.sleep(2)
    resources:
      limits:
        nvidia.com/gpu: 1
  restartPolicy: Never
EOF

echo "Waiting for restore pod..."
for i in {1..120}; do
    STATUS=$(kubectl get pod gpu-restored -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$STATUS" = "Running" ]; then
        echo "✅ Pod restored and running!"
        break
    elif [ "$STATUS" = "Failed" ]; then
        echo "❌ Restore pod failed"
        kubectl describe pod gpu-restored
        exit 1
    fi
    sleep 3
done

if [ "$STATUS" != "Running" ]; then
    echo "❌ Restore timeout"
    kubectl describe pod gpu-restored
    exit 1
fi

# Step 5: Verify GPU memory
echo ""
echo "=== Step 5: Verifying GPU memory restoration ==="
sleep 10

RESTORE_LOGS=$(kubectl logs gpu-restored)
RESTORE_SUM=$(echo "$RESTORE_LOGS" | grep "sum=" | tail -1 | sed 's/.*sum=\([0-9.-]*\).*/\1/')

OK_COUNT=$(echo "$RESTORE_LOGS" | grep -c 'OK' || echo "0")
CORRUPT_COUNT=$(echo "$RESTORE_LOGS" | grep -c 'CORRUPTED' || echo "0")

echo ""
echo "==========================================="
echo "Manual Dump + GRIT Restore Results"
echo "==========================================="
echo ""
echo "Before Checkpoint:"
echo "  Expected sum: $EXPECTED_SUM"
echo ""
echo "After GRIT Restore:"
echo "  Current sum:  $RESTORE_SUM"
echo ""
echo "Verification:"
echo "  OK checks:        $OK_COUNT"
echo "  Corrupted checks: $CORRUPT_COUNT"
echo ""

if [ "$CORRUPT_COUNT" -eq 0 ] && [ "$OK_COUNT" -gt 0 ]; then
    echo "✅✅✅ SUCCESS! ✅✅✅"
    echo "GPU memory preserved across manual dump + GRIT restore!"
    echo ""
    echo "Last 5 lines:"
    kubectl logs gpu-restored --tail=5
    exit 0
else
    echo "❌ FAILED - GPU memory corrupted"
    echo ""
    echo "Full logs:"
    kubectl logs gpu-restored
    exit 1
fi

