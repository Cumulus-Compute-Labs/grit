#!/bin/bash
set -e
SSH_KEY=~/.ssh/krish_key
SOURCE=ubuntu@163.192.28.24
DEST=ubuntu@192.9.133.23
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no"

echo "=== Step 1: Copy real GRIT shim from source to dest ==="
scp $SSH_OPTS $SOURCE:/usr/local/bin/containerd-shim-grit-v1 /tmp/containerd-shim-grit-v1
ls -la /tmp/containerd-shim-grit-v1
echo "Downloaded shim to local machine"

scp $SSH_OPTS /tmp/containerd-shim-grit-v1 $DEST:/tmp/containerd-shim-grit-v1
echo "Uploaded shim to dest node"

ssh $SSH_OPTS $DEST "sudo mv /tmp/containerd-shim-grit-v1 /usr/local/bin/ && sudo chmod +x /usr/local/bin/containerd-shim-grit-v1 && ls -la /usr/local/bin/containerd-shim-grit-v1"
echo "Installed shim on dest node - SUCCESS"
