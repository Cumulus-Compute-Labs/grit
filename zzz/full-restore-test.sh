#!/bin/bash
# Full checkpoint/restore test with descriptors.json fix

set -e

echo "=== Step 1: Cleanup ==="
kubectl delete restore gpu-test-restore --force 2>/dev/null || true
kubectl delete checkpoint gpu-test-ckpt --force 2>/dev/null || true
kubectl delete deployment gpu-test --force 2>/dev/null || true
sudo rm -rf /mnt/grit-agent/default/gpu-test-ckpt 2>/dev/null || true
sleep 5

echo ""
echo "=== Step 2: Create GPU test deployment ==="
cat <<'EOF' | kubectl apply -f -
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
        kubernetes.io/hostname: 192-9-150-56
      containers:
      - name: cuda
        image: pytorch/pytorch:2.1.0-cuda12.1-cudnn8-runtime
        command: ["bash", "-c"]
        args:
        - |
          exec python3 -u -c "
          import torch
          import time
          import os
          
          print('=== GPU Memory Test ===', flush=True)
          print(f'PID: {os.getpid()}', flush=True)
          
          # Create a unique tensor with timestamp
          x = torch.ones(128, 1024, 1024, device='cuda') * float(int(time.time()) % 1000)
          print(f'Tensor value: {x[0,0,0].item()}', flush=True)
          print(f'Tensor sum: {x.sum().item()}', flush=True)
          print(f'GPU memory: {torch.cuda.memory_allocated() / 1024**2:.1f} MB', flush=True)
          
          counter = 0
          while True:
              counter += 1
              if counter % 60 == 0:
                  print(f'Still running... counter={counter}', flush=True)
              time.sleep(1)
          "
        resources:
          limits:
            nvidia.com/gpu: 1
        securityContext:
          privileged: true
EOF

echo ""
echo "=== Step 3: Wait for pod to be running ==="
for i in {1..60}; do
    STATUS=$(kubectl get pod -l app=gpu-test -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    if [ "$STATUS" = "Running" ]; then
        echo "Pod is running!"
        break
    fi
    echo "Waiting... ($i) Status: $STATUS"
    sleep 2
done

# Wait a bit more for CUDA to init
sleep 10

echo ""
echo "=== Step 4: Check pod logs before checkpoint ==="
kubectl logs -l app=gpu-test --tail=10

echo ""
echo "=== Step 5: Create checkpoint ==="
cat <<'EOF' | kubectl apply -f -
apiVersion: kaito.sh/v1alpha1
kind: Checkpoint
metadata:
  name: gpu-test-ckpt
spec:
  podName: gpu-test
  volumeClaim:
    claimName: ckpt-store
EOF

# Wait for checkpoint
echo ""
echo "=== Step 6: Wait for checkpoint to complete ==="
for i in {1..60}; do
    PHASE=$(kubectl get checkpoint gpu-test-ckpt -o jsonpath='{.status.phase}' 2>/dev/null)
    echo "[$i] Checkpoint phase: $PHASE"
    if [ "$PHASE" = "Checkpointed" ]; then
        echo "Checkpoint complete!"
        break
    fi
    if [ "$PHASE" = "Failed" ]; then
        echo "Checkpoint failed!"
        kubectl describe checkpoint gpu-test-ckpt
        exit 1
    fi
    sleep 3
done

echo ""
echo "=== Step 7: Verify descriptors.json exists ==="
ls -la /mnt/grit-agent/default/gpu-test-ckpt/cuda/checkpoint/descriptors.json 2>/dev/null && echo "descriptors.json exists!" || echo "descriptors.json missing!"

echo ""
echo "=== Step 8: Get ReplicaSet UID for restore ==="
RS_NAME=$(kubectl get rs -l app=gpu-test -o jsonpath='{.items[0].metadata.name}')
RS_UID=$(kubectl get rs -l app=gpu-test -o jsonpath='{.items[0].metadata.uid}')
echo "ReplicaSet: $RS_NAME ($RS_UID)"

echo ""
echo "=== Step 9: Scale down and create restore ==="
kubectl scale deployment gpu-test --replicas=0
sleep 5

cat <<EOF | kubectl apply -f -
apiVersion: kaito.sh/v1alpha1
kind: Restore
metadata:
  name: gpu-test-restore
spec:
  checkpointName: gpu-test-ckpt
  ownerRef:
    apiVersion: apps/v1
    kind: ReplicaSet
    name: $RS_NAME
    uid: $RS_UID
EOF

echo ""
echo "=== Step 10: Scale up to trigger restore ==="
sleep 2
kubectl scale deployment gpu-test --replicas=1

echo ""
echo "=== Step 11: Monitor restore ==="
for i in {1..40}; do
    RESTORE_PHASE=$(kubectl get restore gpu-test-restore -o jsonpath='{.status.phase}' 2>/dev/null)
    POD_STATUS=$(kubectl get pod -l app=gpu-test -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    echo "[$i] Restore: $RESTORE_PHASE | Pod: $POD_STATUS"
    
    if [ "$RESTORE_PHASE" = "Restored" ] && [ "$POD_STATUS" = "Running" ]; then
        echo "Restore complete!"
        break
    fi
    
    if [ "$POD_STATUS" = "Failed" ] || [ "$POD_STATUS" = "Error" ]; then
        echo "Pod failed!"
        kubectl describe pod -l app=gpu-test | tail -30
        break
    fi
    
    sleep 3
done

echo ""
echo "=== Final Results ==="
kubectl describe restore gpu-test-restore | tail -20

echo ""
echo "=== Pod Logs After Restore ==="
kubectl logs -l app=gpu-test --tail=20

echo ""
echo "=== GPU Memory Check ==="
nvidia-smi
