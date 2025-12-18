#!/bin/bash
# Smart CRIU Wrapper - injects action script for GPU checkpoint compatibility

# Log for debugging
echo "$(date): CRIU called with: $@" >> /tmp/criu-wrapper.log

# Always inject the action script for dump operations
# The action script handles pre-dump unmount of NVIDIA mounts
exec /usr/local/bin/criu.real "$@" --action-script /usr/local/bin/criu-pre-dump-hook.sh

