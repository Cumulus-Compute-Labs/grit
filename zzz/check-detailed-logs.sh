#!/bin/bash
echo "=== GPU restore detailed logs ==="
sudo journalctl -u containerd --since "3 min ago" | grep -E "(GPU restore|symlink|NEW pod|annotations|checkpoint mount)" | head -50

echo ""
echo "=== runc restore error details ==="
sudo journalctl -u containerd --since "3 min ago" | grep "runc restore failed" | tail -2
