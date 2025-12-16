#!/usr/bin/env python3
import re

config_file = '/var/lib/rancher/k3s/agent/etc/containerd/config.toml'

with open(config_file, 'r') as f:
    content = f.read()

# Remove the grit options section
pattern = r"\[plugins\.'io\.containerd\.cri\.v1\.runtime'\.containerd\.runtimes\.'grit'\.options\][^\[]*"
content = re.sub(pattern, '', content)

with open(config_file, 'w') as f:
    f.write(content)

print('Removed grit options section')
