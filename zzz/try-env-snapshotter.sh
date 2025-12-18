#!/bin/bash
# Try using K3S_OPTS environment variable for snapshotter

echo "=== Trying K3S env approach ==="

# First restore the original service file
sudo cp /etc/systemd/system/k3s.service.bak /etc/systemd/system/k3s.service 2>/dev/null

# Create env file with K3S_OPTS  
echo 'K3S_OPTS="--snapshotter=native"' | sudo tee /etc/systemd/system/k3s.service.env

echo ""
echo "Env file:"
cat /etc/systemd/system/k3s.service.env

echo ""
echo "Stopping k3s..."
sudo systemctl stop k3s
sleep 5

echo "Reloading and starting..."
sudo systemctl daemon-reload
sudo systemctl start k3s

echo "Waiting..."
sleep 25

echo ""
echo "=== Checking k3s ==="
sudo systemctl status k3s --no-pager | head -5

echo ""
echo "=== Delete old pod ==="
kubectl delete pod snap-native-test --force 2>/dev/null
sleep 5

echo ""
echo "=== Check ctr snapshotter ==="
sudo /var/lib/rancher/k3s/data/current/bin/ctr plugins ls 2>/dev/null | grep -i snap

