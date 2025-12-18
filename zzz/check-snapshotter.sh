#!/bin/bash
# Check what snapshotter is being used for new containers

echo "=== Checking snapshotter type ==="

# Get the test pod's container
CONTAINER_ID=$(sudo crictl ps --name test-snap -q | head -1)
echo "Container ID: $CONTAINER_ID"

if [ -n "$CONTAINER_ID" ]; then
    echo ""
    echo "Mount info for this container:"
    mount | grep "$CONTAINER_ID" | head -3
    
    echo ""
    echo "Checking snapshotter directory:"
    ls -la /var/lib/containerd/io.containerd.snapshotter.v1.* 2>/dev/null | head -5
    
    echo ""
    echo "Container rootfs mount:"
    ROOTFS=$(sudo crictl inspect "$CONTAINER_ID" 2>/dev/null | grep -o '"rootfs":[^}]*' | head -1)
    echo "$ROOTFS"
else
    echo "Container not found"
fi

