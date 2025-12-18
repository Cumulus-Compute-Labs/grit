#!/bin/bash
# CRIU Wrapper for CUDA checkpoint
echo "$(date): CRIU called with: $@" >> /tmp/criu-wrapper.log 2>/dev/null || true
exec /usr/local/bin/criu.real "$@" --action-script /usr/local/bin/criu-pre-dump-hook.sh

