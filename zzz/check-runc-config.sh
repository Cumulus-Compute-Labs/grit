#!/bin/bash
# Check runc version and config

echo "=== runc version ==="
runc --version

echo ""
echo "=== Current /etc/criu/runc.conf ==="
cat /etc/criu/runc.conf

echo ""
echo "=== File permissions ==="
ls -la /etc/criu/runc.conf

echo ""
echo "=== Verify no -- prefix (should be clean) ==="
grep "^--" /etc/criu/runc.conf && echo "ERROR: Found -- prefix!" || echo "OK: No -- prefix found"

echo ""
echo "=== Fix config file (remove duplicates, ensure correct format) ==="
sudo tee /etc/criu/runc.conf << 'EOF'
tcp-established
ext-unix-sk
shell-job
ext-mount-map auto
enable-external-masters
enable-external-sharing
mntns-compat-mode
EOF

echo ""
echo "=== Verify fixed config ==="
cat /etc/criu/runc.conf
