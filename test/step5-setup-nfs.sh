#!/bin/bash
set -e
SSH_KEY=~/.ssh/krish_key
SOURCE=ubuntu@163.192.28.24
DEST=ubuntu@192.9.133.23
SOURCE_IP=163.192.28.24
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no"

echo "=== Step 5: Setup NFS for Checkpoint Storage ==="

echo "Configuring NFS server on source node..."
ssh $SSH_OPTS $SOURCE "
    sudo apt-get install -y nfs-kernel-server nfs-common
    
    sudo mkdir -p /exports/grit-checkpoints
    sudo chmod 777 /exports/grit-checkpoints
    
    grep -q '/exports/grit-checkpoints' /etc/exports || \
        echo '/exports/grit-checkpoints *(rw,sync,no_subtree_check,no_root_squash)' | sudo tee -a /etc/exports
    
    sudo exportfs -ra
    sudo systemctl enable nfs-kernel-server
    sudo systemctl restart nfs-kernel-server
    
    # Also create local mount point
    sudo mkdir -p /mnt/grit-checkpoints
    sudo mount --bind /exports/grit-checkpoints /mnt/grit-checkpoints 2>/dev/null || true
    
    echo 'NFS server configured'
"

echo "Configuring NFS client on dest node..."
ssh $SSH_OPTS $DEST "
    sudo apt-get install -y nfs-common
    
    sudo mkdir -p /mnt/grit-checkpoints
    
    # Unmount if exists (in case of stale mount)
    sudo umount /mnt/grit-checkpoints 2>/dev/null || true
    
    # Mount NFS from source
    sudo mount -t nfs $SOURCE_IP:/exports/grit-checkpoints /mnt/grit-checkpoints
    
    # Add to fstab for persistence
    grep -q '$SOURCE_IP:/exports/grit-checkpoints' /etc/fstab || \
        echo '$SOURCE_IP:/exports/grit-checkpoints /mnt/grit-checkpoints nfs defaults,_netdev 0 0' | sudo tee -a /etc/fstab
    
    echo 'NFS client configured'
"

echo "Testing NFS connectivity..."
TESTFILE="test-$(date +%s)"
ssh $SSH_OPTS $SOURCE "echo '$TESTFILE' | sudo tee /mnt/grit-checkpoints/nfs-test.txt"
RESULT=$(ssh $SSH_OPTS $DEST "cat /mnt/grit-checkpoints/nfs-test.txt")
if [ "$RESULT" = "$TESTFILE" ]; then
    echo "NFS TEST PASSED: Both nodes can access shared checkpoint storage"
else
    echo "NFS TEST FAILED: Expected '$TESTFILE' but got '$RESULT'"
    exit 1
fi

echo ""
echo "=== Step 5: NFS Setup Complete ==="
