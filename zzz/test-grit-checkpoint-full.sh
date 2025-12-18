#!/bin/bash
# Full GRIT Checkpoint Test with Fixed Agent

set -e

echo "=== Full GRIT Checkpoint Test ==="
echo ""

HOSTNAME=$(hostname)

# Cleanup
echo "Step 1: Cleanup..."
kubectl delete deployment,pod,checkpoint,job --all --force 2>/dev/null || true
sleep 15

# Create GPU test pod
echo ""
echo "Step 2: Creating GPU test pod..."

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gpu-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gpu-test
  template:
    metadata:
      labels:
        app: gpu-test
    spec:
      runtimeClassName: grit
      nodeSelector:
        kubernetes.io/hostname: $HOSTNAME
      containers:
      - name: cuda
        image: pytorch/pytorch:2.1.0-cuda12.1-cudnn8-runtime
        command: ["python3", "-u", "-c"]
        args:
        - |
          import torch, time, os
          print(f'PID: {os.getpid()}')
          tensor = torch.randn(1024*1024, device='cuda')
          step = 0
          while True:
              step += 1
              print(f'Step {step}: sum={tensor.sum().item()}')
              time.sleep(2)
        resources:
          limits:
            nvidia.com/gpu: 1
EOF

echo "Waiting for pod to start..."
for i in {1..60}; do
    POD=$(kubectl get pods -l app=gpu-test -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    STATUS=$(kubectl get pod $POD -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$STATUS" = "Running" ]; then
        echo "Pod $POD is running!"
        break
    fi
    sleep 3
done

sleep 10
kubectl logs -l app=gpu-test --tail=5

# Create checkpoint
echo ""
echo "Step 3: Creating Checkpoint CR..."

POD_NAME=$(kubectl get pods -l app=gpu-test -o jsonpath='{.items[0].metadata.name}')
echo "Checkpointing pod: $POD_NAME"

cat <<EOF | kubectl apply -f -
apiVersion: kaito.sh/v1alpha1
kind: Checkpoint
metadata:
  name: gpu-test-ckpt
spec:
  podName: $POD_NAME
  autoMigration: false
  volumeClaim:
    claimName: ckpt-store
EOF

# Wait for checkpoint
echo ""
echo "Step 4: Waiting for checkpoint to complete..."

for i in {1..120}; do
    PHASE=$(kubectl get checkpoint gpu-test-ckpt -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    echo "[$i] Checkpoint phase: $PHASE"
    
    if [ "$PHASE" = "Checkpointed" ]; then
        echo ""
        echo "✅ CHECKPOINT SUCCEEDED!"
        break
    elif [ "$PHASE" = "Failed" ]; then
        echo ""
        echo "❌ Checkpoint failed!"
        kubectl describe checkpoint gpu-test-ckpt
        
        # Check agent logs
        echo ""
        echo "=== Agent Job Logs ==="
        kubectl logs -l grit.dev/helper=grit-agent --tail=50
        exit 1
    fi
    
    sleep 3
done

# Check results
echo ""
echo "=== Results ==="
kubectl get checkpoint gpu-test-ckpt

echo ""
echo "=== Checkpoint Files ==="
ls -lh /mnt/grit-agent/default/gpu-test-ckpt/*/checkpoint/ 2>/dev/null | head -10 || echo "Checking alternate path..."
sudo find /mnt/grit-agent -name "*.img" 2>/dev/null | head -10

echo ""
echo "=== Agent Job Status ==="
kubectl get jobs | grep grit-agent
kubectl logs -l grit.dev/helper=grit-agent --tail=20 2>/dev/null || echo "No agent logs"
