#!/bin/bash
# Debug GPU device injection

echo "=== Find latest bundle ==="
BUNDLE=$(sudo find /run/containerd/io.containerd.runtime.v2.task/k8s.io -name config.json -mmin -5 2>/dev/null | head -1)
if [ -z "$BUNDLE" ]; then
    echo "No recent bundles found"
    exit 1
fi

BUNDLE_DIR=$(dirname "$BUNDLE")
echo "Bundle: $BUNDLE_DIR"

echo ""
echo "=== Bundle structure ==="
sudo ls -la "$BUNDLE_DIR"

echo ""
echo "=== Check for rootfs ==="
sudo ls -la "$BUNDLE_DIR/rootfs" 2>/dev/null || echo "No rootfs directory"

echo ""
echo "=== Config.json root section ==="
sudo cat "$BUNDLE" | python3 -c "import sys,json; d=json.load(sys.stdin); print('root:', d.get('root', {}))"

echo ""
echo "=== Host GPU devices ==="
ls -la /dev/nvidia* 2>/dev/null | head -10

echo ""
echo "=== Check shim logs for GPU messages ==="
sudo journalctl -u containerd --since "5 minutes ago" 2>&1 | grep -i "GPU:" | tail -20
