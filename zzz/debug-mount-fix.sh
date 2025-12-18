#!/bin/bash
# Debug mount fix for NVIDIA GPU

echo "=== Debug Mount Fix ==="

# Get GPU pod info
POD=$(kubectl get pods -l app=gpu-test -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$POD" ]; then
    echo "No GPU pod found"
    exit 1
fi
echo "POD: $POD"

# Get container ID and PID  
CONTAINER_ID=$(sudo crictl ps 2>/dev/null | grep -E "gpu-test|cuda" | head -1 | awk '{print $1}')
echo "CONTAINER_ID: $CONTAINER_ID"

# Get PID - look for the info.pid field (skip the namespace pid)
PID=$(sudo crictl inspect $CONTAINER_ID 2>/dev/null | grep '"pid":' | grep -v '"pid": 1' | head -1 | grep -o '[0-9]*')
echo "PID: $PID"

if [ -z "$PID" ]; then
    echo "Could not get PID"
    exit 1
fi

# Check mountinfo for nvidia mounts
echo ""
echo "=== Nvidia mounts in mountinfo ==="
grep nvidia /proc/$PID/mountinfo | head -5

# Check for master_id
echo ""
echo "=== Mounts with master_id ==="
awk '$0 ~ /nvidia/ && $0 ~ /master/' /proc/$PID/mountinfo

# Try the fix
echo ""
echo "=== Attempting mount fix ==="
GPU_MOUNT=$(awk '$5 ~ /nvidia\/gpus/ {print $5; exit}' /proc/$PID/mountinfo)
echo "GPU_MOUNT found: '$GPU_MOUNT'"

if [ -n "$GPU_MOUNT" ]; then
    echo "Running: nsenter -t $PID -m -- mount --make-private $GPU_MOUNT"
    sudo nsenter -t $PID -m -- mount --make-private "$GPU_MOUNT" 2>&1
    echo "Exit code: $?"
    
    echo ""
    echo "=== After fix ==="
    awk '$0 ~ /nvidia/ && $0 ~ /master/' /proc/$PID/mountinfo && echo "Still has master_id!" || echo "SUCCESS: No more master_id"
else
    echo "No GPU mount found to fix"
fi
