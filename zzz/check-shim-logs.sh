#!/bin/bash
# Check shim logs for GPU restore messages

echo "=== Find latest shim log ==="
SHIM_LOG=$(sudo find /run/containerd -name "log.json" -mmin -5 2>/dev/null | head -1)
echo "Shim log: $SHIM_LOG"

if [ -n "$SHIM_LOG" ]; then
    echo ""
    echo "=== Check for GPU restore messages ==="
    sudo cat "$SHIM_LOG" | grep -iE "GPU|criu|restore|annotation|config" | tail -30
    
    echo ""
    echo "=== Full recent log ==="
    sudo cat "$SHIM_LOG" | tail -50
fi

echo ""
echo "=== Check containerd logs for restore ==="
sudo journalctl -u containerd --since "5 minutes ago" 2>/dev/null | grep -iE "GPU|criu|restore|annotation" | tail -20

echo ""
echo "=== Check if criu-gpu.conf was created ==="
sudo find /run/containerd -name "criu-gpu.conf" -mmin -5 2>/dev/null | head -5

echo ""
echo "=== Check bundle config.json for annotation ==="
BUNDLE=$(sudo find /run/containerd -name "config.json" -mmin -3 2>/dev/null | head -1)
if [ -n "$BUNDLE" ]; then
    echo "Bundle config: $BUNDLE"
    sudo cat "$BUNDLE" | grep -A2 "org.criu" || echo "No org.criu annotation found"
fi
