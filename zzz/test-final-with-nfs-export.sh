#!/bin/bash
# FINAL TEST - with nfs_export=on enabled in containerd

CKPT_DIR=/tmp/criu-final-nfs-test

echo "=== FINAL GPU CHECKPOINT TEST (with nfs_export=on) ==="
echo ""

# Step 1: Create new GPU pod
echo "=== Step 1: Creating fresh GPU pod ==="
kubectl delete deployment gpu-nfs-test --force 2>/dev/null || true
sleep 3

cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gpu-nfs-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gpu-nfs-test
  template:
    metadata:
      labels:
        app: gpu-nfs-test
    spec:
      runtimeClassName: nvidia
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
          
          tensor = torch.randn(1024*1024, device='cuda')
          expected = float(tensor.sum().cpu())
          print(f'Sum: {expected}', flush=True)
          print('READY', flush=True)
          
          step = 0
          while True:
              step += 1
              current = float(tensor.sum().cpu())
              status = 'OK' if abs(current - expected) < 0.001 else 'FAIL'
              print(f'Step {step}: {status}', flush=True)
              time.sleep(2)
        resources:
          limits:
            nvidia.com/gpu: "1"
      nodeSelector:
        kubernetes.io/hostname: 192-9-150-56
EOF

echo "Waiting for pod..."
for i in {1..90}; do
    POD=$(kubectl get pods -l app=gpu-nfs-test -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$POD" ]; then
        STATUS=$(kubectl get pod $POD -o jsonpath='{.status.phase}' 2>/dev/null)
        if [ "$STATUS" = "Running" ]; then
            echo "Pod $POD is running"
            break
        fi
    fi
    sleep 3
done
echo "Step 1: OK"

# Wait for CUDA init
echo "Waiting for CUDA..."
for i in {1..60}; do
    if kubectl logs -l app=gpu-nfs-test 2>/dev/null | grep -q "READY"; then
        echo "CUDA ready!"
        kubectl logs -l app=gpu-nfs-test --tail=5
        break
    fi
    sleep 3
done
echo ""
sleep 5

# Step 2: Get container PID
echo "=== Step 2: Getting container PID ==="
CONTAINER_ID=$(sudo crictl ps | grep gpu-app | awk '{print $1}' | head -1)
if [ -z "$CONTAINER_ID" ]; then
    echo "Container not found!"
    exit 1
fi
# Get the Python process PID directly
PID=$(pgrep -f "python3 -u -c" | head -1)
if [ -z "$PID" ]; then
    PID=$(ps aux | grep "python3 -u -c" | grep -v grep | awk '{print $2}' | head -1)
fi
echo "Container: $CONTAINER_ID"
echo "PID: $PID"
echo ""

# Verify nfs_export is enabled on the new container's overlayfs
echo "=== Checking overlayfs mount options ==="
mount | grep "$CONTAINER_ID" | head -1
echo ""

# Step 3: Create action script
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

# Step 4: CUDA checkpoint
echo "=== Step 3: Lock & Checkpoint CUDA ==="
sudo /usr/local/bin/cuda-checkpoint --action lock --pid $PID
sudo /usr/local/bin/cuda-checkpoint --action checkpoint --pid $PID
echo "CUDA state: $(sudo /usr/local/bin/cuda-checkpoint --get-state --pid $PID)"
echo ""

# Step 5: CRIU dump
echo "=== Step 4: CRIU Dump ==="
sudo rm -rf $CKPT_DIR
sudo mkdir -p $CKPT_DIR

echo "Running: criu dump -t $PID --external 'mnt[]' --force-irmap ..."
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

# Results
echo "=== Results ==="
sudo ls -lh $CKPT_DIR/ | head -20

if sudo test -f $CKPT_DIR/core-$PID.img; then
    echo ""
    echo "🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉"
    echo "🎉  SUCCESS! GPU CHECKPOINT CREATED!  🎉"
    echo "🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉"
    echo ""
    sudo du -sh $CKPT_DIR/
    echo ""
    echo "Image files:"
    sudo ls -lh $CKPT_DIR/*.img 2>/dev/null | head -10
else
    echo ""
    echo "❌ FAILED"
    echo ""
    echo "Errors:"
    sudo grep -i error $CKPT_DIR/dump.log | tail -10
fi

