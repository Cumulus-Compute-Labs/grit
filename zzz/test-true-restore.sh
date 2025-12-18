#!/bin/bash
# Test TRUE restore by modifying GPU tensor after init

set -e

echo "=== Testing TRUE GPU Restore ==="
echo ""

HOSTNAME=$(hostname)

# Step 1: Create pod that MODIFIES tensor after init
echo "=== Step 1: Creating pod with dynamic GPU data ==="
kubectl delete pod gpu-dynamic --force 2>/dev/null || true
sleep 5

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gpu-dynamic
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
      import os
      
      print(f'PID: {os.getpid()}', flush=True)
      
      # Start with a base tensor
      tensor = torch.ones(1024*1024, device='cuda')
      print(f'Initial sum: {tensor.sum().item()}', flush=True)
      
      # MODIFY it over time (this won't be reproducible from seed)
      step = 0
      while True:
          step += 1
          # Add step number to tensor - this changes GPU memory
          tensor += step
          current_sum = tensor.sum().item()
          print(f'Step {step}: sum={current_sum}', flush=True)
          if step == 5:
              print('CHECKPOINT_NOW', flush=True)
          time.sleep(2)
    resources:
      limits:
        nvidia.com/gpu: 1
  restartPolicy: Never
EOF

echo "Waiting for pod..."
for i in {1..60}; do
    STATUS=$(kubectl get pod gpu-dynamic -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$STATUS" = "Running" ]; then
        break
    fi
    sleep 2
done

# Wait for step 5
echo "Waiting for checkpoint signal..."
for i in {1..60}; do
    if kubectl logs gpu-dynamic 2>/dev/null | grep -q "CHECKPOINT_NOW"; then
        echo "Ready to checkpoint!"
        break
    fi
    sleep 2
done

sleep 3
BEFORE_SUM=$(kubectl logs gpu-dynamic | grep "Step 5:" | awk '{print $3}' | cut -d= -f2)
echo "Sum before checkpoint: $BEFORE_SUM"

# Step 2: Manual checkpoint
echo ""
echo "=== Step 2: Checkpointing ==="

PID=$(pgrep -f "python3 -u -c" | head -1)
echo "PID: $PID"

CKPT_DIR=/tmp/dynamic-checkpoint
GRIT_DIR=/mnt/grit-agent/default/dynamic-gpu-ckpt

# Action script
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

sudo /usr/local/bin/cuda-checkpoint --action lock --pid $PID
sudo /usr/local/bin/cuda-checkpoint --action checkpoint --pid $PID

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

if [ $? -ne 0 ]; then
    echo "Checkpoint failed!"
    exit 1
fi

echo "✅ Checkpoint created"

# Copy to GRIT location
sudo rm -rf $GRIT_DIR
sudo mkdir -p $GRIT_DIR
sudo cp -r $CKPT_DIR/* $GRIT_DIR/

kubectl delete pod gpu-dynamic --force
sleep 10

# Step 3: Try manual CRIU restore (not GRIT)
echo ""
echo "=== Step 3: Manual CRIU Restore (WILL FAIL - for comparison) ==="
echo "This will fail because we're not in container context..."
cd $CKPT_DIR
timeout 10 sudo /usr/local/bin/criu.real restore -D . -v4 --log-file restore-manual.log --mntns-compat-mode --ext-mount-map auto --restore-detached 2>&1 || echo "Failed as expected"

# Step 4: Check what SUM we get if we restart fresh
echo ""
echo "=== Step 4: Fresh Start (No Restore) ==="
echo "Creating fresh pod to see what sum we get..."

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gpu-fresh
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
      
      tensor = torch.ones(1024*1024, device='cuda')
      
      step = 0
      while True:
          step += 1
          tensor += step
          current_sum = tensor.sum().item()
          print(f'Step {step}: sum={current_sum}', flush=True)
          if step >= 5:
              break
          time.sleep(2)
    resources:
      limits:
        nvidia.com/gpu: 1
  restartPolicy: Never
EOF

sleep 20
FRESH_SUM=$(kubectl logs gpu-fresh 2>/dev/null | grep "Step 5:" | awk '{print $3}' | cut -d= -f2)
echo "Fresh pod Step 5 sum: $FRESH_SUM"

echo ""
echo "==========================================="
echo "Results:"
echo "==========================================="
echo "Checkpointed sum: $BEFORE_SUM"
echo "Fresh start sum:  $FRESH_SUM"
echo ""
echo "If these are the SAME, restore didn't happen (process restarted fresh)"
echo "If DIFFERENT, we need GRIT to properly restore the checkpoint"
echo ""

if [ "$BEFORE_SUM" = "$FRESH_SUM" ]; then
    echo "✅ Sums match - confirms GRIT is NOT restoring, just restarting"
else
    echo "❌ Different sums - something unexpected happened"
fi

