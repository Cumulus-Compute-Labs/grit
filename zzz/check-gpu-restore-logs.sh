#!/bin/bash
echo "=== GPU restore logs ==="
sudo journalctl -u containerd --since "5 minutes ago" 2>&1 | grep -i "GPU restore" | tail -30

echo ""
echo "=== CRIU error logs ==="
sudo journalctl -u containerd --since "5 minutes ago" 2>&1 | grep -iE "criu|stderr|restore.*fail" | tail -30
