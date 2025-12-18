#!/bin/bash
set -e

SSH_KEY=~/.ssh/krish_key
CKPT_NODE=192.9.150.56

echo "=== Building GRIT Manager image on checkpoint node ==="

# Build with BuildKit
ssh -i $SSH_KEY ubuntu@$CKPT_NODE "cd /tmp/grit && DOCKER_BUILDKIT=1 sudo -E docker build -t ghcr.io/kaito-project/grit-manager:main -f docker/grit-manager/Dockerfile ."

echo ""
echo "=== Importing image into containerd ==="
ssh -i $SSH_KEY ubuntu@$CKPT_NODE "sudo docker save ghcr.io/kaito-project/grit-manager:main | sudo ctr -n k8s.io images import -"

echo ""
echo "=== Restarting grit-manager pod ==="
ssh -i $SSH_KEY ubuntu@$CKPT_NODE "kubectl delete pod -n kube-system -l app.kubernetes.io/name=grit-manager"

echo ""
echo "=== Checking pod status ==="
sleep 15
ssh -i $SSH_KEY ubuntu@$CKPT_NODE "kubectl get pods -n kube-system | grep grit"
