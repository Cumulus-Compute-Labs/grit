#!/bin/bash
# Verify the new image has the correct fix

echo "=== Checking grit-agent:gpu-fix image ==="

# Check what binary is in the new image
echo "Files in /usr/local/bin:"
sudo docker run --rm --entrypoint sh grit-agent:gpu-fix -c "ls -la /usr/local/bin/"

echo ""
echo "Checking if host-criu path is in binary..."
RESULT=$(sudo docker run --rm --entrypoint sh grit-agent:gpu-fix -c "strings /usr/local/bin/grit-agent" 2>&1)
echo "$RESULT" | grep -o "host-criu" | head -5
if echo "$RESULT" | grep -q "host-criu"; then
    echo "✅ host-criu found in binary"
else
    echo "❌ host-criu NOT found in binary!"
fi

echo ""
echo "=== Testing if agent starts ==="
sudo docker run --rm --entrypoint /usr/local/bin/grit-agent grit-agent:gpu-fix --help 2>&1 | head -10
