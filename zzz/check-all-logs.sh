#!/bin/bash
echo "=== GPU restore logs (last 10 min) ==="
sudo journalctl -u containerd --since "10 min ago" | grep -i "GPU restore" | head -50

echo ""
echo "=== Symlink creation logs ==="
sudo journalctl -u containerd --since "10 min ago" | grep -i "created symlink" | head -20

echo ""
echo "=== Restore errors ==="
sudo journalctl -u containerd --since "10 min ago" | grep -i "runc restore failed" | tail -3
