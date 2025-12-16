#!/usr/bin/env python3
import re

config_file = '/var/lib/rancher/k3s/agent/etc/containerd/config.toml'

with open(config_file, 'r') as f:
    content = f.read()

# Fix the grit runtime configuration
# Change from io.containerd.runc.v2 with BinaryName to io.containerd.grit.v1
old_grit_section = r'''(\[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\.grit\])
  runtime_type = "io\.containerd\.runc\.v2"
  privileged_without_host_devices = false
  \[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\.grit\.options\]
    BinaryName = "/usr/local/bin/containerd-shim-grit-v1"
    SystemdCgroup = true'''

new_grit_section = '''[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.grit]
  runtime_type = "io.containerd.grit.v1"'''

content = re.sub(old_grit_section, new_grit_section, content, flags=re.MULTILINE)

with open(config_file, 'w') as f:
    f.write(content)

print('Fixed grit runtime config on destination')
