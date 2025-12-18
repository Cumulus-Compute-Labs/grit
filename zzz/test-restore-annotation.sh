#!/bin/bash
# Test GRIT restore with pod annotation approach

set -e

echo "=== Cleanup ==="
kubectl delete pod gpu-test-restored --force 2>/dev/null || true
kubectl delete restore gpu-test-restore --force 2>/dev/null || true
# Keep the checkpoint!
sleep 2

echo ""
echo "=== Verify Checkpoint Exists ==="
kubectl get checkpoint gpu-test-ckpt -o jsonpath='{.status.phase}'
echo ""

echo ""
echo "=== Step 1: Create Restore CRD ==="
cat <<'EOF' | kubectl apply -f -
apiVersion: kaito.sh/v1alpha1
kind: Restore
metadata:
  name: gpu-test-restore
  namespace: default
spec:
  checkpointName: gpu-test-ckpt
EOF

sleep 2

echo ""
echo "=== Step 2: Create Pod with Restore Annotation ==="
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test-restored
  namespace: default
  annotations:
    grit.dev/restore-from: gpu-test-restore
spec:
  runtimeClassName: grit
  restartPolicy: Never
  containers:
  - name: main
    image: pytorch/pytorch:2.1.0-cuda12.1-cudnn8-runtime
    command: ["bash", "-c", "exec python3 -u -c \"
import torch
import time
import os

print('=== GPU Memory Verification ===', flush=True)
print(f'PID: {os.getpid()}', flush=True)

# Try to access existing GPU tensor or create new one
try:
    x = torch.ones(128, 1024, 1024, device='cuda')
    print(f'Tensor shape: {x.shape}', flush=True)
    print(f'Tensor sum: {x.sum().item()}', flush=True)
    print(f'GPU memory: {torch.cuda.memory_allocated() / 1024**2:.1f} MB', flush=True)
except Exception as e:
    print(f'Error: {e}', flush=True)

print('Waiting...', flush=True)
while True:
    time.sleep(60)
\""]
    resources:
      limits:
        nvidia.com/gpu: 1
    securityContext:
      privileged: true
EOF

echo ""
echo "=== Step 3: Monitor Restore ==="
for i in {1..30}; do
    echo ""
    echo "--- Iteration $i ---"
    
    # Check restore status
    RESTORE_PHASE=$(kubectl get restore gpu-test-restore -o jsonpath='{.status.phase}' 2>/dev/null)
    echo "Restore phase: $RESTORE_PHASE"
    
    # Check pod status
    POD_STATUS=$(kubectl get pod gpu-test-restored -o jsonpath='{.status.phase}' 2>/dev/null)
    echo "Pod status: $POD_STATUS"
    
    # Check for grit jobs
    JOBS=$(kubectl get jobs -A 2>/dev/null | grep -i grit || echo "none")
    echo "Grit jobs: $JOBS"
    
    if [ "$POD_STATUS" = "Running" ] || [ "$POD_STATUS" = "Succeeded" ]; then
        echo ""
        echo "=== Pod is Running! ==="
        break
    fi
    
    if [ "$POD_STATUS" = "Failed" ]; then
        echo ""
        echo "=== Pod Failed ==="
        kubectl describe pod gpu-test-restored | tail -30
        break
    fi
    
    sleep 3
done

echo ""
echo "=== Final State ==="
echo "--- Restore ---"
kubectl describe restore gpu-test-restore

echo ""
echo "--- Pod ---"
kubectl describe pod gpu-test-restored | tail -40

echo ""
echo "--- Pod Logs ---"
kubectl logs gpu-test-restored --tail=20 2>/dev/null || echo "No logs yet"

echo ""
echo "--- Grit Manager Logs (last 30 lines) ---"
kubectl logs deployment/grit-manager --tail=30 2>/dev/null | grep -i restore || echo "No restore logs"
