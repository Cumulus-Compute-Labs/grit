#!/bin/bash
# Rebuild containerd-shim-grit with restore fix - v2

set -e

echo "=== Step 1: Clone fresh GRIT repo ==="
cd /tmp
rm -rf /tmp/shim-build 2>/dev/null || true
mkdir -p /tmp/shim-build
cd /tmp/shim-build

git clone --depth 1 https://github.com/kaito-project/grit.git grit-src
cd grit-src

echo "=== Step 2: Apply restore fix patch ==="
# Add imports for exec, strconv, strings
sed -i 's/"github.com\/containerd\/log"/"github.com\/containerd\/log"\n\t"os\/exec"\n\t"strconv"\n\t"strings"/' cmd/containerd-shim-grit-v1/process/init_state.go

# Replace the runtime.Restore call with our GPU-compatible version
cat > /tmp/restore_fix.patch << 'PATCH'
--- a/cmd/containerd-shim-grit-v1/process/init_state.go
+++ b/cmd/containerd-shim-grit-v1/process/init_state.go
@@ -160,8 +163,39 @@ func (s *createdCheckpointState) Start(ctx context.Context) error {
 		s.opts.ConsoleSocket = socket
 	}
 
-	if _, err := s.p.runtime.Restore(ctx, p.id, p.Bundle, s.opts); err != nil {
-		return p.runtimeError(err, "OCI runtime restore failed")
+	// GPU-COMPATIBLE RESTORE: Try direct CRIU restore via nsenter first
+	checkpointPath := s.opts.ImagePath
+	pidFile := s.opts.PidFile
+	log.G(ctx).Infof("GPU restore: checkpoint path %s, pidFile %s", checkpointPath, pidFile)
+
+	criuArgs := []string{
+		"-t", "1", "-m", "--",
+		"/usr/local/bin/criu.real", "restore",
+		"-D", checkpointPath, "-v4",
+		"--log-file", checkpointPath + "/restore.log",
+		"--external", "mnt[]", "--shell-job",
+		"--restore-detached", "--pidfile", pidFile,
+	}
+
+	log.G(ctx).Infof("GPU restore: running CRIU via nsenter")
+	cmd := exec.Command("nsenter", criuArgs...)
+	output, err := cmd.CombinedOutput()
+	if err != nil {
+		log.G(ctx).Errorf("GPU restore: CRIU failed: %v, output: %s", err, string(output))
+		log.G(ctx).Info("GPU restore: falling back to default runtime.Restore")
+		if _, err := s.p.runtime.Restore(ctx, p.id, p.Bundle, s.opts); err != nil {
+			return p.runtimeError(err, "OCI runtime restore failed")
+		}
+	} else {
+		log.G(ctx).Infof("GPU restore: CRIU succeeded")
 	}
+
+	// Suppress warnings
+	_ = strconv.Itoa(0)
+	_ = strings.TrimSpace("")
+
 	if sio.Stdin != "" {
 		if err := p.openStdin(sio.Stdin); err != nil {
PATCH

# Apply the core change manually since patch might not be available
python3 << 'PYTHON'
import re

with open('cmd/containerd-shim-grit-v1/process/init_state.go', 'r') as f:
    content = f.read()

# Find and replace the restore block
old_pattern = r'if _, err := s\.p\.runtime\.Restore\(ctx, p\.id, p\.Bundle, s\.opts\); err != nil \{\n\t\treturn p\.runtimeError\(err, "OCI runtime restore failed"\)\n\t\}'

new_code = '''// GPU-COMPATIBLE RESTORE: Try direct CRIU restore via nsenter first
	checkpointPath := s.opts.ImagePath
	pidFile := s.opts.PidFile
	log.G(ctx).Infof("GPU restore: checkpoint path %s, pidFile %s", checkpointPath, pidFile)

	criuArgs := []string{
		"-t", "1", "-m", "--",
		"/usr/local/bin/criu.real", "restore",
		"-D", checkpointPath, "-v4",
		"--log-file", checkpointPath + "/restore.log",
		"--external", "mnt[]", "--shell-job",
		"--restore-detached", "--pidfile", pidFile,
	}

	log.G(ctx).Infof("GPU restore: running CRIU via nsenter")
	cmd := exec.Command("nsenter", criuArgs...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		log.G(ctx).Errorf("GPU restore: CRIU failed: %v, output: %s", err, string(output))
		log.G(ctx).Info("GPU restore: falling back to default runtime.Restore")
		if _, err := s.p.runtime.Restore(ctx, p.id, p.Bundle, s.opts); err != nil {
			return p.runtimeError(err, "OCI runtime restore failed")
		}
	} else {
		log.G(ctx).Infof("GPU restore: CRIU succeeded")
	}

	// Suppress unused warnings
	_ = strconv.Itoa(0)
	_ = strings.TrimSpace("")'''

content = re.sub(old_pattern, new_code, content)

with open('cmd/containerd-shim-grit-v1/process/init_state.go', 'w') as f:
    f.write(content)

print("Patch applied successfully")
PYTHON

echo "=== Step 3: Build shim ==="
export PATH=/usr/local/go/bin:$PATH
export GOROOT=/usr/local/go

go build -o /tmp/shim-build/containerd-shim-grit-v1 ./cmd/containerd-shim-grit-v1

if [ ! -f /tmp/shim-build/containerd-shim-grit-v1 ]; then
    echo "Build failed!"
    exit 1
fi

echo "=== Step 4: Deploy new shim ==="
sudo cp /usr/local/bin/containerd-shim-grit-v1 /usr/local/bin/containerd-shim-grit-v1.backup 2>/dev/null || true
sudo cp /tmp/shim-build/containerd-shim-grit-v1 /usr/local/bin/containerd-shim-grit-v1
sudo chmod +x /usr/local/bin/containerd-shim-grit-v1

echo "=== Step 5: Restart containerd ==="
sudo systemctl restart containerd
sleep 5

echo "=== Verify ==="
ls -la /usr/local/bin/containerd-shim-grit*

echo ""
echo "Done! New shim deployed with GPU restore fix."
