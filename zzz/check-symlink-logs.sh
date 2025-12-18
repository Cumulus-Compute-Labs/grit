#!/bin/bash
echo "=== GPU restore logs ==="
sudo journalctl -u containerd --since "3 min ago" | grep -i "GPU restore" | head -30

echo ""
echo "=== Symlink logs ==="
sudo journalctl -u containerd --since "3 min ago" | grep -i symlink | head -20

echo ""
echo "=== Crit decode logs ==="
sudo journalctl -u containerd --since "3 min ago" | grep -i crit | head -20

echo ""
echo "=== runc restore errors ==="
sudo journalctl -u containerd --since "3 min ago" | grep "runc restore failed" | head -5

echo ""
echo "=== Check if crit exists ==="
which crit || echo "crit not found!"
