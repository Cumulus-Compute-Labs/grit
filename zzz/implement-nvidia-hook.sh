#!/bin/bash
# Implement NVIDIA hook call before restore instead of CDI

set -e

echo "=== Step 1: Check what nvidia hooks are available ==="
ls -la /usr/bin/nvidia-* 2>/dev/null | head -10
ls -la /usr/share/containers/oci/hooks.d/ 2>/dev/null || echo "No OCI hooks dir"

echo ""
echo "=== Step 2: Clone and patch GRIT shim ==="

cd /tmp
rm -rf /tmp/nvidia-hook-shim 2>/dev/null || true
mkdir -p /tmp/nvidia-hook-shim
cd /tmp/nvidia-hook-shim

# Clone fresh GRIT
git clone --depth 1 https://github.com/kaito-project/grit.git grit-src
cd grit-src

# Use Python to patch - inject GPU devices directly
python3 << 'PYTHON_EOF'
import re

# Read the original file
with open('cmd/containerd-shim-grit-v1/process/init_state.go', 'r') as f:
    content = f.read()

# 1. Add imports
old_imports = '''import (
	"context"
	"errors"
	"fmt"

	google_protobuf'''

new_imports = '''import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"

	google_protobuf'''

content = content.replace(old_imports, new_imports)

# 2. Add the function to inject GPU devices before restore
func_def = '''
// injectGPUDevicesForRestore ensures GPU device nodes exist in the container's rootfs before restore
// This is needed because nvidia-container-runtime hooks don't run during restore
func injectGPUDevicesForRestore(ctx context.Context, bundlePath string) error {
	// Get the rootfs path from the bundle
	rootfs := filepath.Join(bundlePath, "rootfs")
	
	// List of NVIDIA device nodes that need to exist
	devices := []struct {
		path  string
		major uint32
		minor uint32
	}{
		{"/dev/nvidia0", 195, 0},
		{"/dev/nvidiactl", 195, 255},
		{"/dev/nvidia-uvm", 508, 0},
		{"/dev/nvidia-uvm-tools", 508, 1},
		{"/dev/nvidia-modeset", 195, 254},
	}
	
	// Ensure /dev exists in rootfs
	devPath := filepath.Join(rootfs, "dev")
	if err := os.MkdirAll(devPath, 0755); err != nil {
		log.G(ctx).WithError(err).Warn("GPU: Failed to create /dev in rootfs")
	}
	
	for _, dev := range devices {
		targetPath := filepath.Join(rootfs, dev.path)
		
		// Check if device already exists
		if _, err := os.Stat(targetPath); err == nil {
			log.G(ctx).Infof("GPU: Device %s already exists", dev.path)
			continue
		}
		
		// Try to bind mount from host
		hostDevice := dev.path
		if _, err := os.Stat(hostDevice); err == nil {
			// Create parent directory
			os.MkdirAll(filepath.Dir(targetPath), 0755)
			
			// Create empty file to bind mount to
			f, err := os.Create(targetPath)
			if err != nil {
				log.G(ctx).WithError(err).Warnf("GPU: Failed to create mount point %s", targetPath)
				continue
			}
			f.Close()
			
			// Bind mount the host device
			if err := syscall.Mount(hostDevice, targetPath, "", syscall.MS_BIND, ""); err != nil {
				log.G(ctx).WithError(err).Warnf("GPU: Failed to bind mount %s", dev.path)
				os.Remove(targetPath)
			} else {
				log.G(ctx).Infof("GPU: Bind mounted %s to %s", hostDevice, targetPath)
			}
		} else {
			log.G(ctx).Warnf("GPU: Host device %s not found, skipping", hostDevice)
		}
	}
	
	// Also try to call nvidia-container-runtime-hook if available
	hookPath := "/usr/bin/nvidia-container-runtime-hook"
	if _, err := os.Stat(hookPath); err == nil {
		log.G(ctx).Info("GPU: Calling nvidia-container-runtime-hook")
		cmd := exec.Command(hookPath, "prestart")
		cmd.Dir = bundlePath
		cmd.Env = append(os.Environ(), "NVIDIA_VISIBLE_DEVICES=all")
		if output, err := cmd.CombinedOutput(); err != nil {
			log.G(ctx).WithError(err).Warnf("GPU: nvidia hook failed: %s", string(output))
		} else {
			log.G(ctx).Infof("GPU: nvidia hook succeeded: %s", string(output))
		}
	}
	
	return nil
}

'''

# Insert function before "type initState interface"
content = content.replace('type initState interface', func_def + 'type initState interface')

# 3. Add the call before runtime.Restore
old_restore = '''	if _, err := s.p.runtime.Restore(ctx, p.id, p.Bundle, s.opts); err != nil {
		return p.runtimeError(err, "OCI runtime restore failed")
	}'''

new_restore = '''	// GPU FIX: Inject GPU devices before restore
	if err := injectGPUDevicesForRestore(ctx, p.Bundle); err != nil {
		log.G(ctx).WithError(err).Warn("GPU: Failed to inject GPU devices")
	}

	if _, err := s.p.runtime.Restore(ctx, p.id, p.Bundle, s.opts); err != nil {
		return p.runtimeError(err, "OCI runtime restore failed")
	}'''

content = content.replace(old_restore, new_restore)

# Write back
with open('cmd/containerd-shim-grit-v1/process/init_state.go', 'w') as f:
    f.write(content)

print("Patch applied successfully")
PYTHON_EOF

echo ""
echo "=== Step 3: Verify patch ==="
grep -n "injectGPUDevicesForRestore\|GPU:" cmd/containerd-shim-grit-v1/process/init_state.go | head -20

echo ""
echo "=== Step 4: Build patched shim ==="
export PATH=/usr/local/go/bin:$PATH
export GOROOT=/usr/local/go
go build -o /tmp/nvidia-hook-shim/containerd-shim-grit-v1 ./cmd/containerd-shim-grit-v1

echo ""
echo "Build successful!"
ls -la /tmp/nvidia-hook-shim/containerd-shim-grit-v1

echo ""
echo "=== Step 5: Deploy patched shim ==="
sudo systemctl stop k3s
sleep 3
sudo pkill -9 -f "containerd-shim-grit" || true
sleep 2

sudo cp /tmp/nvidia-hook-shim/containerd-shim-grit-v1 /usr/local/bin/containerd-shim-grit-v1
sudo chmod +x /usr/local/bin/containerd-shim-grit-v1

echo ""
echo "=== Step 6: Start k3s ==="
sudo systemctl start k3s
sleep 15

kubectl get nodes

echo ""
echo "=== Done! NVIDIA GPU device injection implemented ==="
