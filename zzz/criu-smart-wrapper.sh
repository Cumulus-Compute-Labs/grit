#!/bin/bash

# Smart CRIU Wrapper - handles swrk mode with environment variables

# Log for debugging
echo "$(date): CRIU called with: $@" >> /tmp/criu-wrapper.log

# Detect if CRIU is being called in swrk mode (runc RPC mode)
if [ "$1" == "swrk" ]; then
    # In swrk mode, CLI flags are ignored. We must use ENV vars.
    echo "$(date): SWRK MODE - setting env vars" >> /tmp/criu-wrapper.log
    
    # Force CRIU to skip the NVIDIA proc mount
    export CRIU_SKIP_MNT="/proc/driver/nvidia/gpus"
    
    # Enable external sharing/masters resolution
    export CRIU_ENABLE_EXTERNAL_MASTERS="1"
    export CRIU_ENABLE_EXTERNAL_SHARING="1"
    
    # Call real CRIU with original args (fd number) unmodified
    exec /usr/local/bin/criu.real "$@"
else
    # Direct CLI mode (e.g. manual testing)
    echo "$(date): CLI MODE - appending flags" >> /tmp/criu-wrapper.log
    exec /usr/local/bin/criu.real "$@" \
        --skip-mnt "/proc/driver/nvidia/gpus" \
        --shell-job
fi

