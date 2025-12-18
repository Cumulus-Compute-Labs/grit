#!/bin/bash
# CRIU Wrapper - injects flags for GPU checkpoint compatibility
echo "$(date): WRAPPER CALLED with args: $@" >> /tmp/criu-wrapper.log
EXTRA_FLAGS="--skip-mnt /proc/driver/nvidia/gpus --shell-job"
echo "$(date): Calling criu.real with: $@ $EXTRA_FLAGS" >> /tmp/criu-wrapper.log
exec /usr/local/bin/criu.real "$@" $EXTRA_FLAGS

