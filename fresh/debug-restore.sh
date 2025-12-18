#!/bin/bash
SSH_KEY="${SSH_KEY:-~/.ssh/krish_key}"
SSH_USER="${SSH_USER:-ubuntu}"
CKPT_NODE="192.9.150.56"

echo "=== Pod Status ==="
ssh -i $SSH_KEY -o StrictHostKeyChecking=no $SSH_USER@$CKPT_NODE "kubectl get pods -l app=gpu-counter -o wide"

echo ""
echo "=== Pod Events ==="
ssh -i $SSH_KEY -o StrictHostKeyChecking=no $SSH_USER@$CKPT_NODE "kubectl describe pod -l app=gpu-counter 2>/dev/null | grep -A30 Events:"

echo ""
echo "=== Container State ==="
ssh -i $SSH_KEY -o StrictHostKeyChecking=no $SSH_USER@$CKPT_NODE "kubectl get pod -l app=gpu-counter -o jsonpath='{.items[0].status.containerStatuses[0]}' 2>/dev/null | python3 -m json.tool 2>/dev/null || kubectl get pod -l app=gpu-counter -o yaml 2>/dev/null | grep -A20 containerStatuses"

echo ""
echo "=== Restore CR Status ==="
ssh -i $SSH_KEY -o StrictHostKeyChecking=no $SSH_USER@$CKPT_NODE "kubectl get restore gpu-counter-restore -o yaml 2>/dev/null | grep -A20 status:"

echo ""
echo "=== Containerd/CRIU Logs ==="
ssh -i $SSH_KEY -o StrictHostKeyChecking=no $SSH_USER@$CKPT_NODE "sudo journalctl -u k3s --since '10 minutes ago' 2>/dev/null | grep -i -E 'criu|restore|RunContainerError|OCI' | tail -20"

echo ""
echo "=== Check checkpoint files ==="
ssh -i $SSH_KEY -o StrictHostKeyChecking=no $SSH_USER@$CKPT_NODE "ls -la /mnt/checkpoint/default/ 2>/dev/null || echo 'No checkpoint dir'"
ssh -i $SSH_KEY -o StrictHostKeyChecking=no $SSH_USER@$CKPT_NODE "ls -la /mnt/grit-agent/default/ 2>/dev/null || echo 'No grit-agent dir'"

echo ""
echo "=== CRIU version ==="
ssh -i $SSH_KEY -o StrictHostKeyChecking=no $SSH_USER@$CKPT_NODE "criu --version 2>/dev/null || echo 'CRIU not found'"
