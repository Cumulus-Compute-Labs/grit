#!/bin/bash
# Quick CRIU test without problematic options

# Get the running Python PID
PID=$(pgrep -f "python3 -c" | head -1)
echo "Python PID: $PID"

if [ -z "$PID" ]; then
    echo "No Python process found!"
    exit 1
fi

# Quick test of CRIU without freeze option
CHECKPOINT_DIR="/tmp/quick-test-$$"
mkdir -p "$CHECKPOINT_DIR"

echo ""
echo "Running CRIU dump (using criu.real)..."
sudo /usr/local/bin/criu.real dump \
    -t "$PID" \
    -D "$CHECKPOINT_DIR" \
    --external 'mnt[]' \
    -v4 \
    --log-file "$CHECKPOINT_DIR/dump.log" \
    --tcp-established \
    --ext-unix-sk \
    --shell-job

CRIU_EXIT=$?
echo ""
echo "CRIU exit code: $CRIU_EXIT"

echo ""
echo "Files created:"
ls -la "$CHECKPOINT_DIR" | head -15

if [ $CRIU_EXIT -ne 0 ]; then
    echo ""
    echo "Last 30 lines of log:"
    tail -30 "$CHECKPOINT_DIR/dump.log"
fi

