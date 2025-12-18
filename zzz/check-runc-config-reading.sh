#!/bin/bash
# Check if runc reads /etc/criu/runc.conf

echo "=== Check runc source for config file path ==="
# runc should look for /etc/criu/runc.conf
runc --help 2>&1 | grep -i criu || echo "No CRIU help in runc"

echo ""
echo "=== Use strace to see if runc reads runc.conf ==="
# Do a quick test with strace on a simple runc command
sudo strace -f -e openat runc spec 2>&1 | grep -i criu || echo "No criu config access during runc spec"

echo ""
echo "=== Check runc version and features ==="
runc --version
runc features 2>&1 | grep -i criu | head -10 || echo "No features command"

echo ""  
echo "=== Check if runc.conf is world readable ==="
ls -la /etc/criu/
cat /etc/criu/runc.conf

echo ""
echo "=== Try running runc restore manually to see config loading ==="
# Create a minimal test to see if runc loads the config
cd /tmp
mkdir -p /tmp/runc-test
cd /tmp/runc-test

# Just try to get runc to show what it would do
sudo strace -f -e openat runc restore --help 2>&1 | grep -E "criu|runc.conf" | head -10 || echo "No config access in help"

echo ""
echo "=== Check runc checkpoint docs ==="
runc checkpoint --help 2>&1 | head -20
