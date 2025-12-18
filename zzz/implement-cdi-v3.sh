#!/bin/bash
# Implement CDI injection for GPU restore - v3 with correct imports

set -e

echo "=== Step 1: CDI spec already generated ==="
ls -la /etc/cdi/nvidia.yaml

echo ""
echo "=== Step 2: Patch GRIT shim ==="

cd /tmp
rm -rf /tmp/cdi-shim 2>/dev/null || true
mkdir -p /tmp/cdi-shim
cd /tmp/cdi-shim

# Clone fresh GRIT
git clone --depth 1 https://github.com/kaito-project/grit.git grit-src
cd grit-src

# Backup original
cp cmd/containerd-shim-grit-v1/process/init_state.go cmd/containerd-shim-grit-v1/process/init_state.go.orig

# Add imports for json, os, filepath
sed -i 's|"context"|"context"\n\t"encoding/json"\n\t"os"\n\t"path/filepath"|' cmd/containerd-shim-grit-v1/process/init_state.go

# Add the injectCDIForGPU function after the imports block - find the closing paren of imports
# Insert the function just before "type stateTransition interface"
sed -i '/^type stateTransition interface/i\
// injectCDIForGPU modifies the OCI config to include CDI GPU annotations for restore\
func injectCDIForGPU(ctx context.Context, bundlePath string) error {\
\tconfigPath := filepath.Join(bundlePath, "config.json")\
\tdata, err := os.ReadFile(configPath)\
\tif err != nil {\
\t\treturn fmt.Errorf("failed to read config.json: %w", err)\
\t}\
\tvar config map[string]interface{}\
\tif err := json.Unmarshal(data, \&config); err != nil {\
\t\treturn fmt.Errorf("failed to parse config.json: %w", err)\
\t}\
\tannotations, ok := config["annotations"].(map[string]interface{})\
\tif !ok {\
\t\tannotations = make(map[string]interface{})\
\t\tconfig["annotations"] = annotations\
\t}\
\tannotations["cdi.k8s.io/gpu"] = "nvidia.com/gpu=all"\
\tlog.G(ctx).Info("CDI: Injected GPU annotation for restore")\
\tnewData, err := json.MarshalIndent(config, "", "  ")\
\tif err != nil {\
\t\treturn fmt.Errorf("failed to marshal config.json: %w", err)\
\t}\
\tif err := os.WriteFile(configPath, newData, 0644); err != nil {\
\t\treturn fmt.Errorf("failed to write config.json: %w", err)\
\t}\
\treturn nil\
}\
' cmd/containerd-shim-grit-v1/process/init_state.go

# Add CDI injection call before runtime.Restore
sed -i '/if _, err := s.p.runtime.Restore/i\
\t// CDI FIX: Inject GPU devices before restore\
\tif err := injectCDIForGPU(ctx, p.Bundle); err != nil {\
\t\tlog.G(ctx).WithError(err).Warn("CDI: Failed to inject GPU annotation")\
\t}\
' cmd/containerd-shim-grit-v1/process/init_state.go

echo ""
echo "=== Step 3: Verify patch ==="
grep -n "CDI\|injectCDIForGPU\|cdi.k8s.io" cmd/containerd-shim-grit-v1/process/init_state.go | head -15
echo ""
echo "Diff:"
diff -u cmd/containerd-shim-grit-v1/process/init_state.go.orig cmd/containerd-shim-grit-v1/process/init_state.go | head -60

echo ""
echo "=== Step 4: Build patched shim ==="
export PATH=/usr/local/go/bin:$PATH
export GOROOT=/usr/local/go
go build -o /tmp/cdi-shim/containerd-shim-grit-v1 ./cmd/containerd-shim-grit-v1

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
