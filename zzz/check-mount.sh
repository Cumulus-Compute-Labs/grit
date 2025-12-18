#!/bin/bash
# Check if native snapshotter is being used

echo "=== Checking mount type for new containers ==="

kubectl get pods
echo ""

CONTAINER_ID=$(sudo crictl ps --name snap-test2 -q | head -1)
echo "Container ID: $CONTAINER_ID"

if [ -n "$CONTAINER_ID" ]; then
    echo ""
    echo "Mount info:"
    mount | grep "$CONTAINER_ID"
    
    echo ""
    echo "Does it use overlayfs or native?"
    if mount | grep "$CONTAINER_ID" | grep -q "overlay"; then
        echo "❌ Still using OVERLAYFS"
    else
        echo "✅ NOT using overlayfs (native snapshotter working!)"
    fi
else
    echo "Container not found"
fi

