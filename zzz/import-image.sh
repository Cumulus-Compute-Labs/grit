#!/bin/bash
# Import grit-agent image to k3s

echo "=== Finding containerd socket ==="
sudo find /run -name "containerd.sock" 2>/dev/null

echo ""
echo "=== Check k3s crictl ==="
sudo crictl --runtime-endpoint unix:///run/k3s/containerd/containerd.sock info 2>/dev/null || \
sudo crictl info 2>/dev/null || \
echo "crictl not working"

echo ""
echo "=== Import using crictl ==="
# First tag the docker image and save to tar
sudo docker save grit-agent:gpu-fix -o /tmp/grit-agent.tar
sudo ctr --address /var/run/containerd/containerd.sock -n k8s.io images import /tmp/grit-agent.tar 2>/dev/null || \
sudo k3s crictl rmi grit-agent:gpu-fix 2>/dev/null || true
sudo k3s crictl pull docker.io/library/grit-agent:gpu-fix 2>/dev/null || \
sudo ctr -a /run/containerd/containerd.sock -n k8s.io images import /tmp/grit-agent.tar 2>/dev/null || \
echo "Trying alternate method..."

# Just use docker and let k3s pull from local docker daemon
# Configure k3s to use local docker images
echo ""
echo "=== Check existing grit-agent images ==="
sudo k3s ctr images ls 2>/dev/null | grep grit || \
sudo crictl images 2>/dev/null | grep grit || true

echo ""
echo "=== Import via crictl ==="
sudo k3s crictl images 2>/dev/null | head -5
