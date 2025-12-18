#!/bin/bash
# Fix EXTERNAL containerd to use native snapshotter

echo "=== Configuring External Containerd for Native Snapshotter ==="

# Step 1: Stop k3s and containerd
echo "Step 1: Stopping services..."
sudo systemctl stop k3s
sudo systemctl stop containerd
sleep 5

# Step 2: Modify containerd config to use native snapshotter
echo ""
echo "Step 2: Updating containerd config..."
sudo sed -i 's/snapshotter = "overlayfs"/snapshotter = "native"/' /etc/containerd/config.toml

echo "Updated config:"
grep snapshotter /etc/containerd/config.toml

# Step 3: Restart containerd
echo ""
echo "Step 3: Restarting containerd..."
sudo systemctl start containerd
sleep 5
sudo systemctl status containerd --no-pager | head -5

# Step 4: Restart k3s
echo ""
echo "Step 4: Restarting k3s..."
sudo systemctl start k3s
sleep 25
sudo systemctl status k3s --no-pager | head -5

# Step 5: Test with new pod
echo ""
echo "Step 5: Creating test pod on this node..."
kubectl delete pod --all --force 2>/dev/null
sleep 5

HOSTNAME=$(hostname)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: native-test
spec:
  nodeSelector:
    kubernetes.io/hostname: "$HOSTNAME"
  containers:
  - name: test
    image: busybox
    command: ["sleep", "300"]
  restartPolicy: Never
EOF

sleep 20

echo ""
echo "Pod status:"
kubectl get pod native-test -o wide

echo ""
echo "=== Checking mount type ==="
CONTAINER_ID=$(sudo crictl ps | grep native-test | awk '{print $1}')
echo "Container ID: $CONTAINER_ID"

if [ -n "$CONTAINER_ID" ]; then
    echo ""
    echo "Mount info:"
    mount | grep "$CONTAINER_ID" || echo "No mount found with container ID in path"
    
    echo ""
    echo "All containerd mounts:"
    mount | grep containerd | head -5
fi

