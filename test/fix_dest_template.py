#!/usr/bin/env python3
import re

# Fix BOTH the template and the config
for config_file in ['/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl', 
                    '/var/lib/rancher/k3s/agent/etc/containerd/config.toml']:
    try:
        with open(config_file, 'r') as f:
            content = f.read()

        # Fix the grit runtime configuration
        # Change runtime_type from io.containerd.runc.v2 to io.containerd.grit.v1
        # And remove the options section with BinaryName
        old_pattern = r'''(\[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\.grit\])
  runtime_type = "io\.containerd\.runc\.v2"
  privileged_without_host_devices = false
  \[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\.grit\.options\]
    BinaryName = "/usr/local/bin/containerd-shim-grit-v1"
    SystemdCgroup = true'''

        new_section = '''[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.grit]
  runtime_type = "io.containerd.grit.v1"'''

        content = re.sub(old_pattern, new_section, content, flags=re.MULTILINE)

        with open(config_file, 'w') as f:
            f.write(content)
        print(f'Fixed {config_file}')
    except Exception as e:
        print(f'Error fixing {config_file}: {e}')
