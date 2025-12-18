#!/bin/bash
# Fix nvidia-container-runtime config for CRIU compatibility

cat > /etc/nvidia-container-runtime/config.toml << 'EOF'
[nvidia-container-runtime]
mode = "legacy"
EOF

echo "Config written:"
cat /etc/nvidia-container-runtime/config.toml

# Restart services
systemctl restart containerd
systemctl restart k3s || systemctl restart k3s-agent || true

echo "Services restarted"

