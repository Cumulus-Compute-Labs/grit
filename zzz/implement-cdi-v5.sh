#!/bin/bash
# Implement CDI injection for GPU restore - v5

set -e

echo "=== Step 1: CDI spec already generated ==="
ls -la /etc/cdi/nvidia.yaml

echo ""
echo "=== Step 2: Clone and patch GRIT shim ==="

cd /tmp
rm -rf /tmp/cdi-shim 2>/dev/null || true
mkdir -p /tmp/cdi-shim
cd /tmp/cdi-shim

# Clone fresh GRIT
git clone --depth 1 https://github.com/kaito-project/grit.git grit-src
cd grit-src

# Use Python to do the patch
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
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	google_protobuf'''

content = content.replace(old_imports, new_imports)

# 2. Add the function definition before "type initState interface"
func_def = '''
// injectCDIForGPU modifies the OCI config to include CDI GPU annotations for restore
func injectCDIForGPU(ctx context.Context, bundlePath string) error {
	configPath := filepath.Join(bundlePath, "config.json")
	data, err := os.ReadFile(configPath)
	if err != nil {
		return fmt.Errorf("failed to read config.json: %w", err)
	}
	var config map[string]interface{}
	if err := json.Unmarshal(data, &config); err != nil {
		return fmt.Errorf("failed to parse config.json: %w", err)
	}
	annotations, ok := config["annotations"].(map[string]interface{})
	if !ok {
		annotations = make(map[string]interface{})
		config["annotations"] = annotations
	}
	annotations["cdi.k8s.io/gpu"] = "nvidia.com/gpu=all"
	log.G(ctx).Info("CDI: Injected GPU annotation for restore")
	newData, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal config.json: %w", err)
	}
	if err := os.WriteFile(configPath, newData, 0644); err != nil {
		return fmt.Errorf("failed to write config.json: %w", err)
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

new_restore = '''	// CDI FIX: Inject GPU devices before restore
	if err := injectCDIForGPU(ctx, p.Bundle); err != nil {
		log.G(ctx).WithError(err).Warn("CDI: Failed to inject GPU annotation")
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
grep -n "injectCDIForGPU\|CDI\|cdi.k8s.io" cmd/containerd-shim-grit-v1/process/init_state.go

echo ""
echo "=== Step 4: Build patched shim ==="
export PATH=/usr/local/go/bin:$PATH
export GOROOT=/usr/local/go
go build -o /tmp/cdi-shim/containerd-shim-grit-v1 ./cmd/containerd-shim-grit-v1

echo ""
echo "Build successful!"
ls -la /tmp/cdi-shim/containerd-shim-grit-v1

echo ""
echo "=== Step 5: Deploy patched shim ==="
sudo systemctl stop k3s
sleep 3
sudo pkill -9 -f "containerd-shim-grit" || true
sleep 2

sudo cp /tmp/cdi-shim/containerd-shim-grit-v1 /usr/local/bin/containerd-shim-grit-v1
sudo chmod +x /usr/local/bin/containerd-shim-grit-v1

echo ""
echo "=== Step 6: Start k3s ==="
sudo systemctl start k3s
sleep 15

kubectl get nodes

echo ""
echo "=== Done! CDI injection implemented ==="
