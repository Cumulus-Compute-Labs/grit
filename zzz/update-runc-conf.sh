#!/bin/bash
# Update runc.conf with working CRIU flags

echo "=== Current runc.conf ==="
cat /etc/criu/runc.conf 2>/dev/null || echo "No config"

echo ""
echo "=== Adding working flags ==="
sudo mkdir -p /etc/criu
sudo tee /etc/criu/runc.conf << 'EOF'
shell-job
external mnt[]
force-irmap
tcp-established
ext-unix-sk
EOF

echo ""
echo "=== Updated config ==="
cat /etc/criu/runc.conf

