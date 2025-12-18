#!/bin/bash
# Check restore details

echo "=== Pod events ==="
kubectl describe pod -l app=gpu-test | grep -A25 Events

echo ""
echo "=== Containerd logs for restore ==="
sudo journalctl -u containerd --since "5 minutes ago" 2>&1 | grep -iE "restore|criu|errno|failed" | tail -40

echo ""
echo "=== Check if runc.conf is being used ==="
echo "runc.conf location:"
ls -la /etc/criu/runc.conf

echo ""
echo "=== Check CRIU restore log ==="
cat /mnt/grit-agent/default/gpu-test-ckpt/cuda/checkpoint/restore.log 2>/dev/null | tail -50 || echo "No restore log"

echo ""
echo "=== Check for any CRIU logs ==="
find /var/log -name "*criu*" 2>/dev/null | head -5
find /tmp -name "*restore*log*" -mmin -10 2>/dev/null | head -5
