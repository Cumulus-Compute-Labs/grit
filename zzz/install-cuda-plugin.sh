#!/bin/bash
# Install CRIU CUDA plugin on Ubuntu

set -e

echo "=== Step 1: Check if plugin already exists ==="
ls -la /usr/lib*/criu/plugins/ 2>/dev/null || echo "No plugins dir"
ls -la /usr/local/lib/criu/plugins/ 2>/dev/null || echo "No local plugins dir"

echo ""
echo "=== Step 2: Check CRIU version ==="
criu --version

echo ""
echo "=== Step 3: Find cuda_plugin in installed packages ==="
dpkg -l | grep criu || echo "No criu packages found via dpkg"

echo ""
echo "=== Step 4: Check if plugin is part of CRIU source ==="
# The CUDA plugin is NOT part of CRIU core - it's in a separate repo
# https://github.com/checkpoint-restore/criu/tree/criu-dev/plugins shows no cuda plugin
# The CUDA plugin comes from NVIDIA: https://github.com/NVIDIA/cuda-checkpoint

echo ""
echo "=== Step 5: Build cuda_plugin from NVIDIA cuda-checkpoint repo ==="
cd /tmp
rm -rf /tmp/cuda-plugin-build 2>/dev/null || true
mkdir -p /tmp/cuda-plugin-build
cd /tmp/cuda-plugin-build

# Clone cuda-checkpoint which includes the CRIU plugin
git clone https://github.com/NVIDIA/cuda-checkpoint.git
cd cuda-checkpoint

echo ""
echo "=== Check contents ==="
ls -la
ls -la plugin/ 2>/dev/null || echo "No plugin dir"
ls -la src/ 2>/dev/null || ls -la

# Build the plugin if there's a makefile
if [ -f Makefile ]; then
    echo ""
    echo "=== Building plugin ==="
    make
fi

# Check for plugin directory structure
find . -name "*.so" -o -name "cuda_plugin*" 2>/dev/null

echo ""
echo "=== Step 6: Check if plugin was built with CRIU from source ==="
# When we built CRIU from source, check if plugin was included
ls -la /usr/lib/criu/plugins/ 2>/dev/null || true
ls -la /usr/local/lib/criu/plugins/ 2>/dev/null || true

echo ""
echo "=== Step 7: Create plugins directory and check dump.log for plugin loading ==="
sudo mkdir -p /usr/lib/criu/plugins
sudo mkdir -p /usr/local/lib/criu/plugins

# Check if plugin was loaded during our successful dump
echo "Checking dump.log for plugin messages:"
grep -i "plugin\|cuda" /mnt/grit-agent/default/gpu-test-ckpt/cuda/checkpoint/dump.log 2>/dev/null | tail -20

echo ""
echo "=== Done ==="
