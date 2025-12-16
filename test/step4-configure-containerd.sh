#!/bin/bash
set -e
SSH_KEY=~/.ssh/krish_key
SOURCE=ubuntu@163.192.28.24
DEST=ubuntu@192.9.133.23
SOURCE_IP=163.192.28.24
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no"

echo "=== Step 4: Configure Containerd on Dest Node ==="

echo "Configuring containerd for NVIDIA + GRIT runtimes..."
ssh $SSH_OPTS $DEST "
    # Configure crictl
    sudo tee /etc/crictl.yaml > /dev/null << 'EOF'
runtime-endpoint: unix:///run/k3s/containerd/containerd.sock
image-endpoint: unix:///run/k3s/containerd/containerd.sock
timeout: 10
EOF

    # Create containerd config directory
    sudo mkdir -p /var/lib/rancher/k3s/agent/etc/containerd
    
    # Create containerd config template with NVIDIA + GRIT runtimes
    sudo tee /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl > /dev/null << 'EOFCONTAINERD'
version = 2

[plugins.\"io.containerd.grpc.v1.cri\".containerd]
  default_runtime_name = \"nvidia\"

[plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.nvidia]
  runtime_type = \"io.containerd.runc.v2\"
  privileged_without_host_devices = false
  [plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.nvidia.options]
    BinaryName = \"/usr/bin/nvidia-container-runtime\"
    SystemdCgroup = true

[plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.grit]
  runtime_type = \"io.containerd.runc.v2\"
  privileged_without_host_devices = false
  [plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.grit.options]
    BinaryName = \"/usr/local/bin/containerd-shim-grit-v1\"
    SystemdCgroup = true

[plugins.\"io.containerd.grpc.v1.cri\".cni]
  bin_dir = \"/var/lib/rancher/k3s/data/current/bin\"
  conf_dir = \"/var/lib/rancher/k3s/agent/etc/cni/net.d\"
EOFCONTAINERD

    echo 'Containerd config created'
    
    # Replace K3s bundled BusyBox tar with GNU tar (needed for CRIU)
    echo 'Replacing K3s BusyBox tar with GNU tar for CRIU compatibility...'
    for tar_path in /var/lib/rancher/k3s/data/*/bin/tar; do
        if [ -L \"\$tar_path\" ]; then
            sudo rm -f \"\$tar_path\"
            sudo cp /usr/bin/tar \"\$tar_path\"
            echo \"  Replaced: \$tar_path\"
        fi
    done
    
    # Restart K3s agent to apply config
    echo 'Restarting K3s agent...'
    sudo systemctl restart k3s-agent
    sleep 10
    
    echo 'K3s agent restarted'
"

echo "Waiting for node to be ready..."
ssh $SSH_OPTS $SOURCE "kubectl wait --for=condition=Ready node/192-9-133-23 --timeout=120s"

echo ""
echo "=== Step 4: Containerd Configuration Complete ==="
ssh $SSH_OPTS $SOURCE "kubectl get nodes"
