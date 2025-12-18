#!/bin/bash
# Run full test and check CRIU args

echo "=== Clear CRIU log ==="
sudo rm -f /tmp/criu-wrapper.log

echo ""
echo "=== Run full restore test ==="
/tmp/full-restore-test-v2.sh 2>&1 | tail -50

echo ""
echo "=== CRIU wrapper log (what runc passed to CRIU) ==="
sudo cat /tmp/criu-wrapper.log 2>/dev/null || echo "No CRIU log found"

echo ""
echo "=== Check for ext-mount-map in CRIU args ==="
sudo grep -i "ext-mount" /tmp/criu-wrapper.log 2>/dev/null || echo "NO ext-mount-map found in CRIU args!"

echo ""
echo "=== Check for restore command ==="
sudo grep -i "restore" /tmp/criu-wrapper.log 2>/dev/null || echo "No restore commands found"
