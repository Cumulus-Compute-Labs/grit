#!/bin/bash
# Debug restore process

echo "=== Check current pod status ==="
kubectl get pod -l app=gpu-test -o wide

echo ""
echo "=== Check pod describe for last failure ==="
kubectl describe pod -l app=gpu-test | grep -A30 "Events:"

echo ""
echo "=== Check containerd logs for more detail ==="
sudo journalctl -u containerd --since "2 minutes ago" 2>&1 | grep -iE "restore|runc|criu|errno|failed|error" | tail -30

echo ""
echo "=== Check containerd task logs for runc ==="
sudo journalctl -u containerd --since "2 minutes ago" 2>&1 | grep -iE "grit|checkpoint" | tail -20

echo ""
echo "=== Check what runc is being used ==="
which runc
runc --version

echo ""
echo "=== Check if nvidia-container-runtime is configured ==="
cat /etc/nvidia-container-runtime/config.toml 2>/dev/null | head -20

echo ""
echo "=== Test: Delete pod and check shim logs during fresh restore ==="
POD=$(kubectl get pod -l app=gpu-test -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$POD" ]; then
    echo "Deleting pod $POD..."
    kubectl delete pod "$POD" --wait=false
    sleep 3
    
    # Force a new pod 
    kubectl scale deployment gpu-test --replicas=0
    sleep 2
    kubectl scale deployment gpu-test --replicas=1
    sleep 5
    
    echo ""
    echo "=== Fresh containerd logs ==="
    sudo journalctl -u containerd --since "30 seconds ago" 2>&1 | grep -E "restore|Restore|RESTORE|errno" | head -20
fi
