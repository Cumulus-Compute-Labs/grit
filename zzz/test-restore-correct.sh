#!/bin/bash
# Test GRIT Restore - Correct workflow

set -e

echo "=== Testing GRIT Restore (Correct Workflow) ==="
echo ""

# Check checkpoint exists
if [ ! -d "/mnt/grit-agent/default/manual-gpu-ckpt" ]; then
    echo "❌ No checkpoint found"
    exit 1
fi

echo "✅ Checkpoint exists"

# Cleanup
kubectl delete restore manual-gpu-restore 2>/dev/null || true
kubectl delete deployment gpu-manual-test 2>/dev/null || true
sleep 10

# Step 1: Create NEW deployment that will be restored
echo "=== Step 1: Creating deployment to be restored ==="

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
          
          # This should be RESTORED, not restarted
          print("Process starting...", flush=True)
          
          torch.manual_seed(42424242)
          tensor = torch.randn(1024*1024, device='cuda')
          
          step = 0
          while True:
              step += 1
              current = float(tensor.sum().cpu())
              print(f'Step {step}: sum={current}', flush=True)
              time.sleep(2)
        resources:
          limits:
            nvidia.com/gpu: 1
      nodeSelector:
        kubernetes.io/hostname: $(hostname)
EOF

echo "Deployment created, waiting for pod..."
sleep 5

POD_NAME=$(kubectl get pods -l app=gpu-manual-test -o jsonpath='{.items[0].metadata.name}')
echo "Pod: $POD_NAME"

# Step 2: Create Restore CR with selector
echo ""
echo "=== Step 2: Creating Restore CR ==="

cat <<EOF | kubectl apply -f -
apiVersion: kaito.sh/v1alpha1
kind: Restore
metadata:
  name: manual-gpu-restore
spec:
  checkpointName: manual-gpu-ckpt
  selector:
    matchLabels:
      app: gpu-manual-test
EOF

echo "Restore CR created"

# Step 3: Watch for restore
echo ""
echo "=== Step 3: Watching restore progress ==="

for i in {1..60}; do
    PHASE=$(kubectl get restore manual-gpu-restore -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    TARGET_POD=$(kubectl get restore manual-gpu-restore -o jsonpath='{.status.targetPod}' 2>/dev/null || echo "")
    
    echo "[$i] Restore phase: $PHASE | Target pod: $TARGET_POD"
    
    if [ "$PHASE" = "Restored" ]; then
        echo "✅ Restore completed!"
        break
    elif [ "$PHASE" = "Failed" ]; then
        echo "❌ Restore failed!"
        kubectl describe restore manual-gpu-restore
        exit 1
    fi
    
    sleep 3
done

# Step 4: Check pod logs
echo ""
echo "=== Step 4: Checking if process was restored ==="
sleep 10

kubectl logs -l app=gpu-manual-test --tail=20

echo ""
echo "=== Analysis ==="
echo "If step counter starts from 1: Process was RESTARTED (restore didn't work)"
echo "If step counter continues from checkpoint: Process was RESTORED (success!)"

# Check GRIT logs
echo ""
echo "=== GRIT Manager Logs ==="
kubectl logs -n kube-system -l app=grit-manager --tail=50 | grep -i -E "restore|checkpoint" || echo "No relevant logs"

