#!/bin/bash
# Test CRIU dump directly

PID=232300

echo "Testing CRIU dump on PID: $PID"
echo "Process status:"
ps -p $PID -o pid,state,comm 2>/dev/null || echo "Process not found!"

echo ""
echo "Creating checkpoint directory..."
sudo rm -rf /tmp/test-criu-direct
sudo mkdir -p /tmp/test-criu-direct

echo ""
echo "Running CRIU dump command:"
echo "sudo /usr/local/bin/criu.real dump --pid $PID -D /tmp/test-criu-direct -v4 --shell-job --tcp-established --ext-unix-sk --log-file /tmp/test-criu-direct/dump.log"

sudo /usr/local/bin/criu.real dump \
    --pid $PID \
    -D /tmp/test-criu-direct \
    -v4 \
    --shell-job \
    --tcp-established \
    --ext-unix-sk \
    --log-file /tmp/test-criu-direct/dump.log

RESULT=$?
echo ""
echo "CRIU exit code: $RESULT"

echo ""
echo "Files created:"
sudo ls -la /tmp/test-criu-direct/

echo ""
echo "Log contents:"
sudo cat /tmp/test-criu-direct/dump.log

