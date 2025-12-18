#!/bin/bash
# Rebuild containerd-shim-grit with restore fix

set -e

echo "=== Step 1: Build shim binary ==="
cd /tmp
rm -rf /tmp/shim-build 2>/dev/null || true
mkdir -p /tmp/shim-build

# Clone GRIT repo
git clone --depth 1 https://github.com/kaito-project/grit.git /tmp/shim-build/grit-src 2>/dev/null || true
cd /tmp/shim-build/grit-src

# Copy updated init_state.go 
cat > cmd/containerd-shim-grit-v1/process/init_state.go << 'GOSOURCE'
//go:build !windows

/*
   Copyright The containerd Authors.

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*/

package process

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strconv"
	"strings"

	google_protobuf "github.com/containerd/containerd/v2/pkg/protobuf/types"
	runc "github.com/containerd/go-runc"
	"github.com/containerd/log"
)

type initState interface {
	Start(context.Context) error
	Delete(context.Context) error
	Pause(context.Context) error
	Resume(context.Context) error
	Update(context.Context, *google_protobuf.Any) error
	Checkpoint(context.Context, *CheckpointConfig) error
	Exec(context.Context, string, *ExecConfig) (Process, error)
	Kill(context.Context, uint32, bool) error
	SetExited(int)
	Status(context.Context) (string, error)
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
		return fmt.Errorf("invalid state transition %q to %q", stateName(s), name)
	}
	return nil
}

func (s *createdState) Pause(ctx context.Context) error {
	return errors.New("cannot pause task in created state")
}

func (s *createdState) Resume(ctx context.Context) error {
	return errors.New("cannot resume task in created state")
}

func (s *createdState) Update(ctx context.Context, r *google_protobuf.Any) error {
	return s.p.update(ctx, r)
}

func (s *createdState) Checkpoint(ctx context.Context, r *CheckpointConfig) error {
	return errors.New("cannot checkpoint a task in created state")
}

func (s *createdState) Start(ctx context.Context) error {
	p := s.p
	if err := p.create(ctx, p.runtime, p.stdio, p.rootfs); err != nil {
		return err
	}
	if err := p.start(ctx); err != nil {
		return err
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
	if err := s.p.setExited(status); err != nil {
		panic(err)
	}
}

func (s *createdState) Exec(ctx context.Context, path string, r *ExecConfig) (Process, error) {
	return s.p.exec(ctx, path, r)
}

func (s *createdState) Status(ctx context.Context) (string, error) {
	return "created", nil
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
		return fmt.Errorf("invalid state transition %q to %q", stateName(s), name)
	}
	return nil
}

func (s *createdCheckpointState) Pause(ctx context.Context) error {
	return errors.New("cannot pause task in created state")
}

func (s *createdCheckpointState) Resume(ctx context.Context) error {
	return errors.New("cannot resume task in created state")
}

func (s *createdCheckpointState) Update(ctx context.Context, r *google_protobuf.Any) error {
	return s.p.update(ctx, r)
}

func (s *createdCheckpointState) Checkpoint(ctx context.Context, r *CheckpointConfig) error {
	return errors.New("cannot checkpoint a task in created state")
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

	// GPU-COMPATIBLE RESTORE: Use direct CRIU restore via nsenter
	checkpointPath := s.opts.ImagePath
	pidFile := s.opts.PidFile
	log.G(ctx).Infof("GPU restore: checkpoint path %s, pidFile %s", checkpointPath, pidFile)

	// Run CRIU restore via nsenter into HOST's mount namespace
	criuArgs := []string{
		"-t", "1",
		"-m", "--",
		"/usr/local/bin/criu.real",
		"restore",
		"-D", checkpointPath,
		"-v4",
		"--log-file", checkpointPath + "/restore.log",
		"--external", "mnt[]",
		"--shell-job",
		"--restore-detached",
		"--pidfile", pidFile,
	}

	log.G(ctx).Infof("GPU restore: running CRIU via nsenter: %v", criuArgs)
	cmd := exec.Command("nsenter", criuArgs...)

	output, err := cmd.CombinedOutput()
	if err != nil {
		log.G(ctx).Errorf("GPU restore: CRIU via nsenter failed: %v, output: %s", err, string(output))
		log.G(ctx).Info("GPU restore: falling back to default runtime.Restore")
		if _, err := s.p.runtime.Restore(ctx, p.id, p.Bundle, s.opts); err != nil {
			return p.runtimeError(err, "OCI runtime restore failed")
		}
	} else {
		log.G(ctx).Infof("GPU restore: CRIU succeeded, output: %s", string(output))
	}

	_ = strconv.Itoa(0)
	_ = strings.TrimSpace("")

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
	if err := s.p.setExited(status); err != nil {
		panic(err)
	}
}

func (s *createdCheckpointState) Exec(ctx context.Context, path string, r *ExecConfig) (Process, error) {
	return nil, errors.New("cannot exec in a checkpointed state")
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
	case "paused":
		s.p.initState = &pausedState{p: s.p}
	default:
		return fmt.Errorf("invalid state transition %q to %q", stateName(s), name)
	}
	return nil
}

func (s *runningState) Pause(ctx context.Context) error {
	if err := s.p.runtime.Pause(ctx, s.p.id); err != nil {
		return s.p.runtimeError(err, "OCI runtime pause failed")
	}
	return s.transition("paused")
}

func (s *runningState) Resume(ctx context.Context) error {
	return errors.New("cannot resume a running process")
}

func (s *runningState) Update(ctx context.Context, r *google_protobuf.Any) error {
	return s.p.update(ctx, r)
}

func (s *runningState) Checkpoint(ctx context.Context, r *CheckpointConfig) error {
	return s.p.checkpoint(ctx, r)
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
	if err := s.p.setExited(status); err != nil {
		panic(err)
	}
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

type pausedState struct {
	p *Init
}

func (s *pausedState) transition(name string) error {
	switch name {
	case "running":
		s.p.initState = &runningState{p: s.p}
	case "stopped":
		s.p.initState = &stoppedState{p: s.p}
	default:
		return fmt.Errorf("invalid state transition %q to %q", stateName(s), name)
	}
	return nil
}

func (s *pausedState) Pause(ctx context.Context) error {
	return errors.New("cannot pause a paused container")
}

func (s *pausedState) Resume(ctx context.Context) error {
	if err := s.p.runtime.Resume(ctx, s.p.id); err != nil {
		return s.p.runtimeError(err, "OCI runtime resume failed")
	}
	return s.transition("running")
}

func (s *pausedState) Update(ctx context.Context, r *google_protobuf.Any) error {
	return s.p.update(ctx, r)
}

func (s *pausedState) Checkpoint(ctx context.Context, r *CheckpointConfig) error {
	return s.p.checkpoint(ctx, r)
}

func (s *pausedState) Start(ctx context.Context) error {
	return errors.New("cannot start a paused process")
}

func (s *pausedState) Delete(ctx context.Context) error {
	return errors.New("cannot delete a paused process")
}

func (s *pausedState) Kill(ctx context.Context, sig uint32, all bool) error {
	return s.p.kill(ctx, sig, all)
}

func (s *pausedState) SetExited(status int) {
	if err := s.p.setExited(status); err != nil {
		panic(err)
	}
	if err := s.transition("stopped"); err != nil {
		panic(err)
	}
}

func (s *pausedState) Exec(ctx context.Context, path string, r *ExecConfig) (Process, error) {
	return nil, errors.New("cannot exec in a paused state")
}

func (s *pausedState) Status(ctx context.Context) (string, error) {
	return "paused", nil
}

type stoppedState struct {
	p *Init
}

func (s *stoppedState) transition(name string) error {
	switch name {
	case "deleted":
		s.p.initState = &deletedState{}
	default:
		return fmt.Errorf("invalid state transition %q to %q", stateName(s), name)
	}
	return nil
}

func (s *stoppedState) Pause(ctx context.Context) error {
	return errors.New("cannot pause a stopped container")
}

func (s *stoppedState) Resume(ctx context.Context) error {
	return errors.New("cannot resume a stopped container")
}

func (s *stoppedState) Update(ctx context.Context, r *google_protobuf.Any) error {
	return errors.New("cannot update a stopped container")
}

func (s *stoppedState) Checkpoint(ctx context.Context, r *CheckpointConfig) error {
	return errors.New("cannot checkpoint a stopped container")
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

func (s *stoppedState) Kill(ctx context.Context, sig uint32, all bool) error {
	return s.p.kill(ctx, sig, all)
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
GOSOURCE

# Build the shim
export PATH=/usr/local/go/bin:$PATH
export GOROOT=/usr/local/go

echo "Building containerd-shim-grit-v1..."
go build -o /tmp/shim-build/containerd-shim-grit-v1 ./cmd/containerd-shim-grit-v1

echo ""
echo "=== Step 2: Deploy new shim ==="
# Backup old shim
sudo cp /usr/local/bin/containerd-shim-grit-v1 /usr/local/bin/containerd-shim-grit-v1.backup 2>/dev/null || true

# Install new shim
sudo cp /tmp/shim-build/containerd-shim-grit-v1 /usr/local/bin/containerd-shim-grit-v1
sudo chmod +x /usr/local/bin/containerd-shim-grit-v1

echo ""
echo "=== Step 3: Restart containerd ==="
sudo systemctl restart containerd
sleep 5

echo ""
echo "=== Verify ==="
/usr/local/bin/containerd-shim-grit-v1 --version 2>&1 || echo "Shim installed"
ls -la /usr/local/bin/containerd-shim-grit*

echo ""
echo "Done! New shim deployed."
