#!/bin/bash
set -e
SSH_KEY=~/.ssh/krish_key
SOURCE=ubuntu@163.192.28.24
DEST=ubuntu@192.9.133.23
SOURCE_IP=163.192.28.24
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no"

echo "=== Step 3: Join Dest Node to Source's K3s Cluster ==="

echo "Getting current cluster status..."
ssh $SSH_OPTS $SOURCE "kubectl get nodes"
echo ""

echo "Uninstalling standalone K3s from dest node..."
ssh $SSH_OPTS $DEST "
    if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
        echo 'Uninstalling existing K3s...'
        sudo /usr/local/bin/k3s-uninstall.sh || true
        sleep 5
    else
        echo 'No K3s to uninstall'
    fi
"

echo "Getting K3s join token from source node..."
K3S_TOKEN=$(ssh $SSH_OPTS $SOURCE "sudo cat /var/lib/rancher/k3s/server/node-token")
echo "Got K3s token: ${K3S_TOKEN:0:30}..."

echo "Installing K3s agent on dest node (joining cluster)..."
ssh $SSH_OPTS $DEST "
    export K3S_URL='https://$SOURCE_IP:6443'
    export K3S_TOKEN='$K3S_TOKEN'
    curl -sfL https://get.k3s.io | sh -s - agent
    
    sleep 10
    echo 'K3s agent installed'
"

echo "Waiting for node to join cluster..."
for i in {1..30}; do
    NODES=$(ssh $SSH_OPTS $SOURCE "kubectl get nodes --no-headers 2>/dev/null | wc -l")
    echo "  Nodes in cluster: $NODES (waiting for 2...)"
    if [ "$NODES" -ge 2 ]; then
        echo "  Dest node joined!"
        break
    fi
    sleep 5
done

echo ""
echo "=== Cluster Status ==="
ssh $SSH_OPTS $SOURCE "kubectl get nodes -o wide"
echo ""
echo "=== Step 3: Cluster Join Complete ==="
