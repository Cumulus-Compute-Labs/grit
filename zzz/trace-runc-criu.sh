#!/bin/bash
# Trace what runc passes to CRIU during restore

echo "=== Create a wrapper to log CRIU calls ==="
sudo tee /usr/local/bin/criu-trace << 'WRAPPER'
#!/bin/bash
# Log all CRIU invocations
echo "$(date): criu called with: $@" >> /tmp/criu-trace.log
exec /usr/local/bin/criu.real "$@"
WRAPPER
sudo chmod +x /usr/local/bin/criu-trace

echo ""
echo "=== Point runc to use criu-trace ==="
# runc uses PATH to find criu, let's see what it uses
which criu
ls -la /usr/local/bin/criu*

echo ""
echo "=== Check current CRIU wrapper ==="
cat /usr/local/bin/criu

echo ""
echo "=== Update CRIU wrapper to also log ==="
sudo tee /usr/local/bin/criu << 'WRAPPER'
#!/bin/bash
# Log all CRIU invocations with full arguments
echo "$(date '+%Y-%m-%d %H:%M:%S'): CRIU called" >> /tmp/criu-wrapper.log
echo "  args: $@" >> /tmp/criu-wrapper.log
echo "  pwd: $(pwd)" >> /tmp/criu-wrapper.log
exec /usr/local/bin/criu.real "$@"
WRAPPER
sudo chmod +x /usr/local/bin/criu

echo ""
echo "=== Clear old logs ==="
sudo rm -f /tmp/criu-wrapper.log /tmp/criu-trace.log

echo ""
echo "=== Test that wrapper works ==="
criu --version
cat /tmp/criu-wrapper.log || echo "No log yet"
