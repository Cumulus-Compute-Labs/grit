#!/bin/bash
# Check restore logs

echo "=== Check containerd logs for restore errors ==="
sudo journalctl -u containerd --since "5 minutes ago" 2>/dev/null | grep -iE "criu|restore|errno|ext-mount" | tail -30

echo ""
echo "=== Check pod events ==="
kubectl get events --sort-by='.lastTimestamp' | grep -i gpu-test | tail -20

echo ""
echo "=== Check pod status ==="
POD=$(kubectl get pod -l app=gpu-test -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
echo "Pod: $POD"
kubectl describe pod "$POD" 2>/dev/null | tail -30

echo ""
echo "=== Check if process is running in pod ==="
kubectl exec "$POD" -c cuda -- ps aux 2>/dev/null || echo "Cannot exec into pod"

echo ""
echo "=== Check pod logs ==="
kubectl logs "$POD" -c cuda 2>/dev/null | tail -20 || echo "No logs"
