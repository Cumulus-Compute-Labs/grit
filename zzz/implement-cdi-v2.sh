#!/bin/bash
# Implement CDI injection for GPU restore - v2 with correct imports

set -e

echo "=== Step 1: CDI spec already generated ==="
ls -la /etc/cdi/nvidia.yaml

echo ""
echo "=== Step 2: Patch GRIT shim with correct imports ==="

cd /tmp
rm -rf /tmp/cdi-shim 2>/dev/null || true
mkdir -p /tmp/cdi-shim
cd /tmp/cdi-shim

# Clone fresh GRIT
git clone --depth 1 https://github.com/kaito-project/grit.git grit-src
cd grit-src

# Create patched init_state.go with CDI injection
cat > cmd/containerd-shim-grit-v1/process/init_state.go << 'EOF'
package process

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/containerd/containerd/v2/pkg/process"
	"github.com/containerd/log"
	"github.com/kaito-project/grit/cmd/containerd-shim-grit-v1/runc"
)

type stateTransition interface {
	transition(name string) error
}

type createdState struct {
	p *Init
}

func (s *createdState) transition(name string) error {
	switch name {
	case "running":
		s.p.initState = &runningState{p: s.p}
	case "stopped":
		s.p.initState = &stoppedState{p: s.p}
	case "deleted":
		s.p.initState = &deletedState{}
	default:
		return fmt.Errorf("invalid state transition %q to %q", "created", name)
	}
	return nil
}

func (s *createdState) Start(ctx context.Context) error {
	p := s.p
	if err := p.runtime.Start(ctx, p.id); err != nil {
		return p.runtimeError(err, "OCI runtime start failed")
	}
	return s.transition("running")
}

func (s *createdState) Delete(ctx context.Context) error {
	if err := s.p.delete(ctx); err != nil {
		return err
	}
	return s.transition("deleted")
}

func (s *createdState) Kill(ctx context.Context, sig uint32, all bool) error {
	return s.p.kill(ctx, sig, all)
}

func (s *createdState) SetExited(status int) {
	s.p.setExited(status)

	if err := s.transition("stopped"); err != nil {
		panic(err)
	}
}

func (s *createdState) Exec(ctx context.Context, path string, r *ExecConfig) (Process, error) {
	return nil, errors.New("cannot exec in a created state")
}

func (s *createdState) Status(ctx context.Context) (string, error) {
	return "created", nil
}

func (s *createdState) Stdio() process.Stdio {
	return s.p.stdio
}

// injectCDIForGPU modifies the OCI config to include CDI GPU annotations for restore
func injectCDIForGPU(ctx context.Context, bundlePath string) error {
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
	log.G(ctx).Info("CDI: Injected GPU annotation for restore")
	
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

type createdCheckpointState struct {
	p    *Init
	opts *runc.RestoreOpts
}

func (s *createdCheckpointState) transition(name string) error {
	switch name {
	case "running":
		s.p.initState = &runningState{p: s.p}
	case "stopped":
		s.p.initState = &stoppedState{p: s.p}
	case "deleted":
		s.p.initState = &deletedState{}
	default:
		return fmt.Errorf("invalid state transition %q to %q", "created", name)
	}
	return nil
}

func (s *createdCheckpointState) Start(ctx context.Context) error {
	p := s.p
	sio := p.stdio
	var (
		err    error
		socket *runc.Socket
	)
	if sio.Terminal {
		if socket, err = runc.NewTempConsoleSocket(); err != nil {
			return fmt.Errorf("failed to create OCI runtime console socket: %w", err)
		}
		defer socket.Close()
		s.opts.ConsoleSocket = socket
	}

	// CDI FIX: Inject GPU devices before restore
	// This adds cdi.k8s.io/gpu annotation to config.json so runc can inject GPU devices
	if err := injectCDIForGPU(ctx, p.Bundle); err != nil {
		log.G(ctx).WithError(err).Warn("CDI: Failed to inject GPU annotation, restore may fail for GPU workloads")
	}

	if _, err := s.p.runtime.Restore(ctx, p.id, p.Bundle, s.opts); err != nil {
		return p.runtimeError(err, "OCI runtime restore failed")
	}
	if sio.Stdin != "" {
		if err := p.openStdin(sio.Stdin); err != nil {
			return fmt.Errorf("failed to open stdin fifo %s: %w", sio.Stdin, err)
		}
	}
	if socket != nil {
		console, err := socket.ReceiveMaster()
		if err != nil {
			return fmt.Errorf("failed to retrieve console master: %w", err)
		}
		console, err = p.Platform.CopyConsole(ctx, console, p.id, sio.Stdin, sio.Stdout, sio.Stderr, &p.wg)
		if err != nil {
			return fmt.Errorf("failed to start console copy: %w", err)
		}
		p.console = console
	} else {
		if err := p.io.Copy(ctx, &p.wg); err != nil {
			return fmt.Errorf("failed to start io pipe copy: %w", err)
		}
	}
	pid, err := runc.ReadPidFile(s.opts.PidFile)
	if err != nil {
		return fmt.Errorf("failed to retrieve OCI runtime container pid: %w", err)
	}
	p.pid = pid
	return s.transition("running")
}

func (s *createdCheckpointState) Delete(ctx context.Context) error {
	if err := s.p.delete(ctx); err != nil {
		return err
	}
	return s.transition("deleted")
}

func (s *createdCheckpointState) Kill(ctx context.Context, sig uint32, all bool) error {
	return s.p.kill(ctx, sig, all)
}

func (s *createdCheckpointState) SetExited(status int) {
	s.p.setExited(status)

	if err := s.transition("stopped"); err != nil {
		panic(err)
	}
}

func (s *createdCheckpointState) Exec(ctx context.Context, path string, r *ExecConfig) (Process, error) {
	return nil, errors.New("cannot exec in a created state")
}

func (s *createdCheckpointState) Status(ctx context.Context) (string, error) {
	return "created", nil
}

type runningState struct {
	p *Init
}

func (s *runningState) transition(name string) error {
	switch name {
	case "stopped":
		s.p.initState = &stoppedState{p: s.p}
	default:
		return fmt.Errorf("invalid state transition %q to %q", "running", name)
	}
	return nil
}

func (s *runningState) Start(ctx context.Context) error {
	return errors.New("cannot start a running process")
}

func (s *runningState) Delete(ctx context.Context) error {
	return errors.New("cannot delete a running process")
}

func (s *runningState) Kill(ctx context.Context, sig uint32, all bool) error {
	return s.p.kill(ctx, sig, all)
}

func (s *runningState) SetExited(status int) {
	s.p.setExited(status)

	if err := s.transition("stopped"); err != nil {
		panic(err)
	}
}

func (s *runningState) Exec(ctx context.Context, path string, r *ExecConfig) (Process, error) {
	return s.p.exec(ctx, path, r)
}

func (s *runningState) Status(ctx context.Context) (string, error) {
	return "running", nil
}

type stoppedState struct {
	p *Init
}

func (s *stoppedState) transition(name string) error {
	switch name {
	case "deleted":
		s.p.initState = &deletedState{}
	default:
		return fmt.Errorf("invalid state transition %q to %q", "stopped", name)
	}
	return nil
}

func (s *stoppedState) Start(ctx context.Context) error {
	return errors.New("cannot start a stopped process")
}

func (s *stoppedState) Delete(ctx context.Context) error {
	if err := s.p.delete(ctx); err != nil {
		return err
	}
	return s.transition("deleted")
}

func (s *stoppedState) Kill(_ context.Context, sig uint32, _ bool) error {
	return s.p.kill(context.Background(), sig, false)
}

func (s *stoppedState) SetExited(status int) {
	// no op
}

func (s *stoppedState) Exec(ctx context.Context, path string, r *ExecConfig) (Process, error) {
	return nil, errors.New("cannot exec in a stopped state")
}

func (s *stoppedState) Status(ctx context.Context) (string, error) {
	return "stopped", nil
}

type deletedState struct{}

func (s *deletedState) transition(name string) error {
	return fmt.Errorf("invalid state transition %q from deleted", name)
}

func (s *deletedState) Start(ctx context.Context) error {
	return errors.New("cannot start a deleted process")
}

func (s *deletedState) Delete(ctx context.Context) error {
	return errors.New("cannot delete a deleted process")
}

func (s *deletedState) Kill(ctx context.Context, sig uint32, all bool) error {
	return fmt.Errorf("cannot kill deleted process")
}

func (s *deletedState) SetExited(status int) {
	// no op
}

func (s *deletedState) Exec(ctx context.Context, path string, r *ExecConfig) (Process, error) {
	return nil, errors.New("cannot exec in a deleted state")
}

func (s *deletedState) Status(ctx context.Context) (string, error) {
	return "stopped", nil
}
EOF

echo ""
echo "=== Step 3: Verify patch ==="
grep -n "CDI\|injectCDIForGPU\|cdi.k8s.io" cmd/containerd-shim-grit-v1/process/init_state.go | head -10

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
