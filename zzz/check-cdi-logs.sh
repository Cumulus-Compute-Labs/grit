#!/bin/bash
# Check CDI injection logs

echo "=== Containerd logs for CDI/restore ==="
sudo journalctl -u containerd --since "3 minutes ago" 2>&1 | grep -iE "CDI|Restore|criu|errno|failed|error" | tail -40

echo ""
echo "=== Pod events ==="
kubectl describe pod -l app=gpu-test | grep -A20 Events

echo ""
echo "=== Check if CDI annotation was added ==="
# Find the latest container bundle
LATEST_BUNDLE=$(sudo find /run/containerd/io.containerd.runtime.v2.task/k8s.io -name config.json -mmin -5 2>/dev/null | head -1)
if [ -n "$LATEST_BUNDLE" ]; then
    echo "Latest bundle: $LATEST_BUNDLE"
    sudo grep -o "cdi.k8s.io[^\"]*" "$LATEST_BUNDLE" 2>/dev/null || echo "No CDI annotation found"
else
    echo "No recent bundles found"
fi
