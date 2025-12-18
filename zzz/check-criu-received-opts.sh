#!/bin/bash
# Check what options CRIU actually received during restore

echo "=== Find the latest CRIU work directory ==="
WORK_DIR=$(sudo find /run/containerd -name "work" -type d -mmin -5 2>/dev/null | head -1)
echo "Work dir: $WORK_DIR"

echo ""
echo "=== Find restore.log ==="
RESTORE_LOG=$(sudo find /run/containerd -name "restore.log" -mmin -5 2>/dev/null | head -1)
echo "Restore log: $RESTORE_LOG"

if [ -n "$RESTORE_LOG" ]; then
    echo ""
    echo "=== Check restore.log for ext-mount-map ==="
    sudo grep -i "ext-mount\|external" "$RESTORE_LOG" | head -20
    
    echo ""
    echo "=== Check restore.log head (shows CRIU options) ==="
    sudo head -50 "$RESTORE_LOG"
    
    echo ""
    echo "=== Check restore.log for errors ==="
    sudo grep -i "error\|failed\|err -" "$RESTORE_LOG" | head -20
fi

echo ""
echo "=== Alternative: Check what runc log shows ==="
# runc may log to containerd
sudo journalctl -u containerd --since "5 minutes ago" 2>/dev/null | grep -i "criu\|runc.*restore" | tail -20

echo ""
echo "=== Check shim log for any CRIU details ==="
SHIM_LOG=$(sudo find /run/containerd -name "log.json" -mmin -3 2>/dev/null | head -1)
if [ -n "$SHIM_LOG" ]; then
    echo "Shim log: $SHIM_LOG"
    sudo cat "$SHIM_LOG" | grep -i "criu\|restore" | tail -10
fi
