#!/bin/bash
# Check mountinfo format for ALL mounts with master:

# Get GPU container
CONTAINER_ID=$(sudo crictl ps | grep -E "cuda|gpu-test" | head -1 | awk '{print $1}')
if [ -z "$CONTAINER_ID" ]; then
    echo "No GPU container found"
    exit 1
fi
echo "Container: $CONTAINER_ID"

# Get PID
PID=$(sudo crictl inspect $CONTAINER_ID | grep '"pid":' | grep -v '"pid": 1' | head -1 | grep -o '[0-9]*')
echo "PID: $PID"

# Show ALL mounts with master:
echo ""
echo "=== ALL mounts with 'master:' ==="
grep "master:" /proc/$PID/mountinfo

echo ""
echo "=== Total mounts with master: ==="
grep -c "master:" /proc/$PID/mountinfo || echo "0"

echo ""
echo "=== Extracting mount paths from lines with master: ==="
awk '$0 ~ /master:/ {print $5}' /proc/$PID/mountinfo
