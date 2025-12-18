#!/bin/bash
# Find CUDA plugin

echo "=== Search for cuda_plugin files ==="
sudo find / -name "*cuda*plugin*" 2>/dev/null | head -10
sudo find / -name "cuda_plugin.so" 2>/dev/null | head -10

echo ""
echo "=== Check CRIU built-in plugins ==="
/usr/local/bin/criu.real check 2>&1 | head -10

echo ""
echo "=== grep dump.log for cuda ==="
grep -i cuda /mnt/grit-agent/default/gpu-test-ckpt/cuda/checkpoint/dump.log 2>/dev/null | head -30

echo ""
echo "=== Check if cuda plugin compiled with CRIU ==="
strings /usr/local/bin/criu.real 2>/dev/null | grep -i cuda | head -10

echo ""
echo "=== CRIU help for plugins ==="
/usr/local/bin/criu.real --help 2>&1 | grep -i plugin
