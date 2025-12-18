#!/bin/bash
# Fix the Dockerfile to put grit-agent in the right place

set -e

echo "=== Step 1: Find where grit-agent is in the image ==="
LOCATION=$(sudo docker run --rm --entrypoint sh grit-agent:gpu-fix -c "find / -name 'grit-agent' -type f 2>/dev/null" || echo "not found")
echo "Found at: $LOCATION"

echo ""
echo "=== Step 2: Check current Dockerfile ==="
cat /tmp/grit-build/docker/grit-agent/Dockerfile

echo ""
echo "=== Step 3: Fix Dockerfile ==="
# The Dockerfile copies to /grit-agent but ConfigMap expects /usr/local/bin/grit-agent
# Fix by adding a line to copy/link to /usr/local/bin

cd /tmp/grit-build

# Check if already has the fix
if grep -q "/usr/local/bin/grit-agent" docker/grit-agent/Dockerfile; then
    echo "Dockerfile already has /usr/local/bin/grit-agent"
else
    echo "Adding /usr/local/bin/grit-agent to Dockerfile..."
    
    # Add a line to copy the binary to /usr/local/bin as well
    sed -i '/^COPY --from=builder.*grit-agent/a RUN mkdir -p /usr/local/bin && cp /grit-agent /usr/local/bin/grit-agent' docker/grit-agent/Dockerfile
fi

echo ""
echo "=== Updated Dockerfile ==="
cat docker/grit-agent/Dockerfile

echo ""
echo "=== Step 4: Rebuild image ==="
sudo docker build --no-cache -t grit-agent:gpu-fix -f docker/grit-agent/Dockerfile . 2>&1 | tail -15

echo ""
echo "=== Step 5: Verify binary location ==="
sudo docker run --rm --entrypoint sh grit-agent:gpu-fix -c "ls -la /usr/local/bin/grit-agent && /usr/local/bin/grit-agent --version"

echo ""
echo "=== Step 6: Import to containerd ==="
sudo ctr -n k8s.io images rm docker.io/library/grit-agent:gpu-fix 2>/dev/null || true
sudo docker save grit-agent:gpu-fix | sudo ctr -n k8s.io images import -

echo ""
echo "✅ Done! Image rebuilt with binary at /usr/local/bin/grit-agent"
