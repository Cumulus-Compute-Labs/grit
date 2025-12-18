#!/bin/bash
# CRIU Wrapper with action script for mount propagation fix
echo "$(date): CRIU called with: $@" >> /tmp/criu-wrapper.log 2>/dev/null || true

# Only add action-script for dump operations (not swrk)
if [[ "$1" == "dump" ]]; then
    exec /usr/local/bin/criu.real "$@" --action-script /usr/local/bin/criu-pre-dump-hook.sh
else
    exec /usr/local/bin/criu.real "$@"
fi

