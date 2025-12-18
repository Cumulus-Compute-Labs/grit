#!/bin/bash
# Final GPU Checkpoint Test with Native Snapshotter

echo "=== FINAL GPU CHECKPOINT TEST (Native Snapshotter) ==="

HOSTNAME=$(hostname)

# Cleanup
echo ""
echo "=== Step 1: Cleanup ==="
kubectl delete pod --all --force 2>/dev/null
kubectl delete deployment --all --force 2>/dev/null
sleep 10

# Create GPU pod
echo ""
echo "=== Step 2: Create GPU Pod ==="
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gpu-checkpoint-test
spec:
  nodeSelector:
    kubernetes.io/hostname: "$HOSTNAME"
  runtimeClassName: nvidia
  containers:
  - name: cuda
    image: pytorch/pytorch:2.1.0-cuda12.1-cudnn8-runtime
    command: ["python3", "-c"]
    args:
    - |
      import torch
      import time
      import os
      
      print(f"PID: {os.getpid()}")
      print(f"CUDA: {torch.cuda.is_available()}")
      
      if torch.cuda.is_available():
          x = torch.randn(1000, 1000, device='cuda')
          print(f"Sum: {x.sum().item()}")
          print("READY")
          while True:
              time.sleep(10)
              print(f"Alive @ {time.time()}")
      else:
          print("NO GPU")
          time.sleep(3600)
    resources:
      limits:
        nvidia.com/gpu: 1
    securityContext:
      privileged: true
      seccompProfile:
        type: Unconfined
      capabilities:
        add: ["SYS_ADMIN"]
  restartPolicy: Never
EOF

echo "Waiting for pod..."
for i in {1..60}; do
    STATUS=$(kubectl get pod gpu-checkpoint-test -o jsonpath='{.status.phase}' 2>/dev/null)
    if [ "$STATUS" = "Running" ]; then
        break
    fi
    sleep 5
done

kubectl get pod gpu-checkpoint-test -o wide

# Wait for CUDA init
echo ""
echo "Waiting for CUDA initialization..."
for i in {1..30}; do
    if kubectl logs gpu-checkpoint-test 2>/dev/null | grep -q "READY"; then
        break
    fi
    sleep 2
done

kubectl logs gpu-checkpoint-test | tail -5

# Get container PID - find the Python process
echo ""
echo "=== Step 3: Get Python Process PID ==="
CONTAINER_ID=$(sudo crictl ps | grep gpu-checkpoint-test | awk '{print $1}')
echo "Container ID: $CONTAINER_ID"

# Get the ACTUAL Python process PID from /proc
# Look inside the container's cgroup for python3
PID=$(pgrep -f "python3 -c" | head -1)
if [ -z "$PID" ]; then
    # Try another method - find python3 process
    PID=$(ps aux | grep "python3 -c" | grep -v grep | awk '{print $2}' | head -1)
fi
echo "Python PID: $PID"

# Verify it's the right process
echo "Process info:"
ps -p "$PID" -o pid,ppid,comm,args | head -2

# Verify mount type
echo ""
echo "=== Step 4: Verify Mount Type ==="
mount | grep "$CONTAINER_ID" | head -1
if mount | grep "$CONTAINER_ID" | grep -q "overlay"; then
    echo "⚠️  Still using overlayfs"
else
    echo "✅ Using native snapshotter (ext4)"
fi

# CUDA checkpoint
echo ""
echo "=== Step 5: CUDA Lock & Checkpoint ==="
sudo /usr/local/bin/cuda-checkpoint --pid "$PID" --action lock || echo "Lock failed (code $?)"
sleep 1
sudo /usr/local/bin/cuda-checkpoint --pid "$PID" --action checkpoint || echo "Checkpoint failed (code $?)"
sleep 1
echo "CUDA state:"
sudo /usr/local/bin/cuda-checkpoint --pid "$PID" --get-state 2>&1 || true

# Make mounts private
echo ""
echo "=== Step 6: Make Slave Mounts Private ==="
SLAVE_MOUNTS=$(awk '$6 ~ /master/ {print $5}' "/proc/$PID/mountinfo" 2>/dev/null | sort -u)
if [ -n "$SLAVE_MOUNTS" ]; then
    echo "Slave mounts found:"
    echo "$SLAVE_MOUNTS"
    echo "$SLAVE_MOUNTS" | while read -r mnt_path; do
        if [ -n "$mnt_path" ]; then
            echo "Making private: $mnt_path"
            nsenter -t "$PID" -m -- mount --make-private "$mnt_path" 2>/dev/null || true
        fi
    done
else
    echo "No slave mounts found"
fi

# CRIU dump
echo ""
echo "=== Step 7: CRIU Dump ==="
CHECKPOINT_DIR="/tmp/gpu-checkpoint-$(date +%s)"
mkdir -p "$CHECKPOINT_DIR"

echo "Running: criu dump -t $PID --external 'mnt[]' -v4..."
sudo criu dump \
    -t "$PID" \
    -D "$CHECKPOINT_DIR" \
    --external 'mnt[]' \
    -v4 \
    --log-file="$CHECKPOINT_DIR/dump.log" \
    --tcp-established \
    --ext-unix-sk \
    --shell-job \
    --no-freeze

CRIU_EXIT=$?
echo ""
echo "CRIU exit code: $CRIU_EXIT"

# Results
echo ""
echo "=== Results ==="
ls -lah "$CHECKPOINT_DIR"

if [ $CRIU_EXIT -eq 0 ]; then
    echo ""
    echo "✅ SUCCESS! GPU checkpoint completed!"
    echo ""
    echo "Checkpoint files:"
    ls "$CHECKPOINT_DIR"/*.img 2>/dev/null | head -10
else
    echo ""
    echo "❌ FAILED"
    echo ""
    echo "Last 30 lines of log:"
    tail -30 "$CHECKPOINT_DIR/dump.log"
fi

