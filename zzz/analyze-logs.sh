#!/bin/bash
# Analyze all logs to understand the problem

echo "=== 1. Containerd logs (last 5 min) ==="
sudo journalctl -u containerd --since "5 minutes ago" 2>/dev/null | grep -iE "GPU|runc|restore|criu|error|failed" | tail -50

echo ""
echo "=== 2. Check if runc was called directly ==="
sudo journalctl -u containerd --since "5 minutes ago" 2>/dev/null | grep "calling runc directly"

echo ""
echo "=== 3. Check runc restore output ==="
sudo journalctl -u containerd --since "5 minutes ago" 2>/dev/null | grep "runc restore"

echo ""
echo "=== 4. Pod status ==="
POD=$(kubectl get pod -l app=gpu-test -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
echo "Pod: $POD"
kubectl get pod "$POD" -o wide 2>/dev/null

echo ""
echo "=== 5. Pod events ==="
kubectl describe pod "$POD" 2>/dev/null | grep -A20 "Events:"

echo ""
echo "=== 6. Check if process is running ==="
kubectl exec "$POD" -c cuda -- ps aux 2>/dev/null || echo "Cannot exec"

echo ""
echo "=== 7. Check nvidia-smi inside pod ==="
kubectl exec "$POD" -c cuda -- nvidia-smi 2>/dev/null || echo "Cannot run nvidia-smi"

echo ""
echo "=== 8. Check pod logs ==="
kubectl logs "$POD" -c cuda 2>/dev/null | tail -20 || echo "No logs"

echo ""
echo "=== 9. Check criu-gpu.conf was created ==="
sudo find /run/containerd -name "criu-gpu.conf" -mmin -10 2>/dev/null | head -3

echo ""
echo "=== 10. Check bundle config.json for annotation ==="
BUNDLE=$(sudo find /run/containerd -name "config.json" -path "*k8s.io*" -mmin -5 2>/dev/null | head -1)
if [ -n "$BUNDLE" ]; then
    echo "Bundle: $BUNDLE"
    sudo grep "org.criu" "$BUNDLE" 2>/dev/null || echo "No org.criu annotation"
fi
