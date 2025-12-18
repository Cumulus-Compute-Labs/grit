#!/bin/bash
# Test GRIT Restore

echo "=== Current checkpoint ==="
kubectl get checkpoint gpu-test-ckpt -o yaml | grep -A5 "spec:"

echo ""
echo "=== Deleting old deployment and creating fresh one ==="
kubectl delete deployment gpu-test --force 2>/dev/null || true
kubectl delete restore gpu-test-restore --force 2>/dev/null || true
sleep 3

# Create a new deployment (GRIT will restore into this)
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
            nvidia.com/gpu: "1"
      nodeSelector:
        kubernetes.io/hostname: 192-9-150-56
EOF

echo "Waiting for pod..."
sleep 10
kubectl get pods -l app=gpu-test

echo ""
echo "=== Creating Restore CRD ==="
cat <<EOF | kubectl apply -f -
apiVersion: kaito.sh/v1alpha1
kind: Restore
metadata:
  name: gpu-test-restore
spec:
  checkpointName: gpu-test-ckpt
  selector:
    matchLabels:
      app: gpu-test
EOF

echo ""
echo "=== Waiting for restore ==="
for i in {1..30}; do
    PHASE=$(kubectl get restore gpu-test-restore -o jsonpath='{.status.phase}' 2>/dev/null)
    echo "[$i] Restore phase: $PHASE"
    if [ "$PHASE" = "Restored" ] || [ "$PHASE" = "Failed" ]; then
        break
    fi
    sleep 3
done

echo ""
echo "=== Restore Status ==="
kubectl get restore gpu-test-restore -o yaml | tail -40

echo ""
echo "=== Pods ==="
kubectl get pods

echo ""
echo "=== Restored Pod Logs (if exists) ==="
kubectl logs gpu-restored --tail=10 2>/dev/null || echo "No restored pod logs yet"
