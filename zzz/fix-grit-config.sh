#!/bin/bash
# Fix grit.toml configuration

cat > /etc/containerd/grit.toml << 'GRITEOF'
BinaryName = "/usr/bin/nvidia-container-runtime"
Root = "/run/containerd/runc"
SystemdCgroup = false
GRITEOF

echo "Updated grit.toml:"
cat /etc/containerd/grit.toml

# Restart k3s service
if systemctl is-active --quiet k3s; then
    systemctl restart k3s
elif systemctl is-active --quiet k3s-agent; then
    systemctl restart k3s-agent
fi

echo "Done"

