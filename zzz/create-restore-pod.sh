#!/bin/bash
# Create GRIT restore pod

HOSTNAME=$(hostname)

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gpu-restored
  annotations:
    grit.dev/checkpoint: "/mnt/grit-agent/default/manual-gpu-ckpt"
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

echo ""
echo "Waiting for pod..."
for i in {1..120}; do
    STATUS=$(kubectl get pod gpu-restored -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$STATUS" = "Running" ]; then
        echo "✅ Pod running!"
        break
    elif [ "$STATUS" = "Failed" ]; then
        echo "❌ Pod failed"
        kubectl describe pod gpu-restored
        exit 1
    fi
    sleep 3
done

if [ "$STATUS" != "Running" ]; then
    echo "Pod status: $STATUS"
    kubectl describe pod gpu-restored | tail -20
else
    echo ""
    echo "Waiting for logs..."
    sleep 10
    kubectl logs gpu-restored --tail=10
fi

