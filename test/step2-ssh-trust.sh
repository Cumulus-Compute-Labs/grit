#!/bin/bash
set -e
SSH_KEY=~/.ssh/krish_key
SOURCE=ubuntu@163.192.28.24
DEST=ubuntu@192.9.133.23
SOURCE_IP=163.192.28.24
DEST_IP=192.9.133.23
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no"

echo "=== Step 2: Setup SSH Key Trust Between Nodes ==="

echo "Getting/creating SSH key on source node..."
ssh $SSH_OPTS $SOURCE "
    if [ ! -f ~/.ssh/id_rsa ]; then
        ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa
    fi
    cat ~/.ssh/id_rsa.pub
" > /tmp/source_pubkey.txt
echo "Got source public key"

echo "Adding source's key to dest's authorized_keys..."
ssh $SSH_OPTS $DEST "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
cat /tmp/source_pubkey.txt | ssh $SSH_OPTS $DEST "cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys"
echo "Added key to dest"

echo "Getting dest's host key..."
DEST_HOSTKEY=$(ssh $SSH_OPTS $DEST "cat /etc/ssh/ssh_host_ecdsa_key.pub")

echo "Adding dest's host key to source's known_hosts..."
ssh $SSH_OPTS $SOURCE "
    grep -q '$DEST_IP' ~/.ssh/known_hosts 2>/dev/null || echo '$DEST_IP $DEST_HOSTKEY' >> ~/.ssh/known_hosts
    grep -q '192-9-133-23' ~/.ssh/known_hosts 2>/dev/null || echo '192-9-133-23 $DEST_HOSTKEY' >> ~/.ssh/known_hosts
"
echo "Added host key"

echo "Testing SSH from source to dest..."
ssh $SSH_OPTS $SOURCE "ssh -o StrictHostKeyChecking=no -o BatchMode=yes ubuntu@$DEST_IP 'echo SSH from source to dest: SUCCESS'" || echo "SSH test failed - may need manual setup"

echo "=== SSH Trust Setup Complete ==="
