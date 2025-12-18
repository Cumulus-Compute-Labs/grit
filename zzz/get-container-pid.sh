#!/bin/bash
# Get the container PID for the gpu-app container
CONTAINER_ID=$(sudo crictl ps --name gpu-app -q | head -1)
if [ -z "$CONTAINER_ID" ]; then
    echo "ERROR: Container not found"
    exit 1
fi

echo "CONTAINER_ID=$CONTAINER_ID"

# Get PID using python to parse JSON
PID=$(sudo crictl inspect "$CONTAINER_ID" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['info']['pid'])")
echo "PID=$PID"

# Verify it's the Python process
echo "Process info:"
ps -p "$PID" -o pid,ppid,comm,args

# Also show what cuda-checkpoint sees
echo ""
echo "Testing cuda-checkpoint:"
sudo /usr/local/cuda/bin/cuda-checkpoint --pid "$PID" --action status 2>&1 || echo "Status check returned: $?"

