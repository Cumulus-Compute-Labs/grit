#!/bin/bash
# Test native snapshotter on checkpoint node

echo "=== Testing Native Snapshotter on Checkpoint Node ==="

# Cleanup
kubectl delete pod snap-test2 snap-test3 --force 2>/dev/null
sleep 5

# Get checkpoint node hostname
HOSTNAME=$(hostname)
echo "Checkpoint node: $HOSTNAME"

# Create pod that runs on THIS node using a YAML approach
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: snap-native-test
spec:
  nodeSelector:
    kubernetes.io/hostname: "$HOSTNAME"
  containers:
  - name: test
    image: busybox
    command: ["sleep", "300"]
  restartPolicy: Never
EOF

echo "Waiting for pod..."
sleep 20

kubectl get pod snap-native-test -o wide

echo ""
echo "=== Checking container mount type ==="
CONTAINER_ID=$(sudo crictl ps | grep snap-native | awk '{print $1}')
echo "Container ID: $CONTAINER_ID"

if [ -n "$CONTAINER_ID" ]; then
    echo ""
    echo "Mount info:"
    mount | grep "$CONTAINER_ID"
    
    if mount | grep "$CONTAINER_ID" | grep -q "overlayfs"; then
        echo "❌ Still using OVERLAYFS"
    else
        echo "✅ NOT using overlayfs - native snapshotter working!"
    fi
else
    echo "Container not found on this node"
fi

