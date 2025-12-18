#!/bin/bash
# CRIU Wrapper - injects flags for GPU checkpoint compatibility

EXTRA_FLAGS="--skip-mnt /proc/driver/nvidia/gpus --shell-job"

# Call real CRIU with original args plus extra flags
exec /usr/local/bin/criu.real "$@" $EXTRA_FLAGS

