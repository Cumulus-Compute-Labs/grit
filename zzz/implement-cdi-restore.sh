#!/bin/bash
# Implement CDI injection for GPU restore

set -e

echo "=== Step 1: Generate CDI spec on host ==="
sudo mkdir -p /etc/cdi
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
echo "CDI spec generated:"
head -30 /etc/cdi/nvidia.yaml

echo ""
echo "=== Step 2: Patch GRIT shim to inject CDI before restore ==="

cd /tmp
rm -rf /tmp/cdi-shim 2>/dev/null || true
mkdir -p /tmp/cdi-shim
cd /tmp/cdi-shim

# Clone fresh GRIT
git clone --depth 1 https://github.com/kaito-project/grit.git grit-src
cd grit-src

# Apply CDI injection patch to init_state.go
cat > /tmp/cdi-patch.go << 'PATCH_EOF'
// CDI injection code - add before restore call in Start() method

// injectCDIForGPU modifies the OCI config to include CDI GPU annotations
func injectCDIForGPU(bundlePath string) error {
	configPath := filepath.Join(bundlePath, "config.json")
	
	// Read existing config
	data, err := os.ReadFile(configPath)
	if err != nil {
		return fmt.Errorf("failed to read config.json: %w", err)
	}
	
	// Parse as generic JSON to preserve structure
	var config map[string]interface{}
	if err := json.Unmarshal(data, &config); err != nil {
		return fmt.Errorf("failed to parse config.json: %w", err)
	}
	
	// Get or create annotations
	annotations, ok := config["annotations"].(map[string]interface{})
	if !ok {
		annotations = make(map[string]interface{})
		config["annotations"] = annotations
	}
	
	// Add CDI GPU annotation
	annotations["cdi.k8s.io/gpu"] = "nvidia.com/gpu=all"
	
	// Write back
	newData, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal config.json: %w", err)
	}
	
	if err := os.WriteFile(configPath, newData, 0644); err != nil {
		return fmt.Errorf("failed to write config.json: %w", err)
	}
	
	return nil
}
PATCH_EOF

# Now modify init_state.go to add CDI injection before restore
INIT_STATE="cmd/containerd-shim-grit-v1/process/init_state.go"

# Add imports
sed -i 's/import (/import (\n\t"encoding\/json"/' "$INIT_STATE"

# Add the injectCDIForGPU function before the createdCheckpointState struct
# Find the line with "type createdCheckpointState struct" and insert before it
sed -i '/^type createdCheckpointState struct/i\
// injectCDIForGPU modifies the OCI config to include CDI GPU annotations for restore\
func injectCDIForGPU(bundlePath string) error {\
\tlogger := log.L\
\tconfigPath := filepath.Join(bundlePath, "config.json")\
\t\
\t// Read existing config\
\tdata, err := os.ReadFile(configPath)\
\tif err != nil {\
\t\treturn fmt.Errorf("failed to read config.json: %w", err)\
\t}\
\t\
\t// Parse as generic JSON to preserve structure\
\tvar config map[string]interface{}\
\tif err := json.Unmarshal(data, \&config); err != nil {\
\t\treturn fmt.Errorf("failed to parse config.json: %w", err)\
\t}\
\t\
\t// Get or create annotations\
\tannotations, ok := config["annotations"].(map[string]interface{})\
\tif !ok {\
\t\tannotations = make(map[string]interface{})\
\t\tconfig["annotations"] = annotations\
\t}\
\t\
\t// Add CDI GPU annotation\
\tannotations["cdi.k8s.io/gpu"] = "nvidia.com/gpu=all"\
\tlogger.Info("Injected CDI GPU annotation for restore")\
\t\
\t// Write back\
\tnewData, err := json.MarshalIndent(config, "", "  ")\
\tif err != nil {\
\t\treturn fmt.Errorf("failed to marshal config.json: %w", err)\
\t}\
\t\
\tif err := os.WriteFile(configPath, newData, 0644); err != nil {\
\t\treturn fmt.Errorf("failed to write config.json: %w", err)\
\t}\
\t\
\treturn nil\
}\
' "$INIT_STATE"

# Add CDI injection call before the runtime.Restore call
# Find "if _, err := s.p.runtime.Restore" and add CDI injection before it
sed -i '/if _, err := s.p.runtime.Restore/i\
\t// Inject CDI GPU devices before restore\
\tif err := injectCDIForGPU(p.Bundle); err != nil {\
\t\tlog.G(ctx).WithError(err).Warn("Failed to inject CDI GPU annotation, restore may fail for GPU workloads")\
\t}\
' "$INIT_STATE"

echo ""
echo "=== Step 3: Verify patch applied ==="
grep -n "injectCDIForGPU\|cdi.k8s.io" "$INIT_STATE" | head -20

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
echo "=== Step 6: Verify CDI is available ==="
ls -la /etc/cdi/
cat /etc/cdi/nvidia.yaml | head -50

echo ""
echo "=== Step 7: Start k3s ==="
sudo systemctl start k3s
sleep 15

kubectl get nodes

echo ""
echo "=== Done! CDI injection implemented ==="
echo "Run the full restore test to verify GPU devices are injected"
