#!/bin/bash
# CRIU Wrapper - simple passthrough
echo "$(date): CRIU called with: $@" >> /tmp/criu-wrapper.log 2>/dev/null || true
exec /usr/local/bin/criu.real "$@"

