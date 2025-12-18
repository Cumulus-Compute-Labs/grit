#!/bin/bash
# Add --snapshotter=native to k3s service

echo "=== Adding --snapshotter=native ==="

sudo systemctl stop k3s
sleep 3

# Backup
sudo cp /etc/systemd/system/k3s.service /etc/systemd/system/k3s.service.bak

# Add the flag after 'server \' line
sudo sed -i "/^[[:space:]]*server/a\\	'--snapshotter=native' \\\\" /etc/systemd/system/k3s.service

echo "=== Modified service ==="
grep -A 10 "ExecStart" /etc/systemd/system/k3s.service

sudo systemctl daemon-reload
sudo systemctl start k3s

echo "Waiting for k3s..."
sleep 25

echo ""
echo "=== k3s status ==="
sudo systemctl status k3s --no-pager | head -5

echo ""
echo "=== Delete old pods ==="
kubectl delete pod --all --force 2>/dev/null

sleep 10

echo ""
echo "=== Create fresh test pod ==="
kubectl run snap-test2 --image=busybox --restart=Never --command -- sleep 300
sleep 15

echo ""
echo "=== Check mount type ==="
CONTAINER_ID=$(sudo crictl ps --name snap-test2 -q | head -1)
echo "Container: $CONTAINER_ID"
if [ -n "$CONTAINER_ID" ]; then
    mount | grep "$CONTAINER_ID"
else
    echo "Container not found yet"
fi

