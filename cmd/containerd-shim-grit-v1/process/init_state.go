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
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
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
	if err := s.p.start(ctx); err != nil {
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
	s.p.setExited(status)

	if err := s.transition("stopped"); err != nil {
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

	// GPU-COMPATIBLE RESTORE: Call runc directly to bypass nvidia-container-runtime
	// nvidia-container-runtime does NOT support the restore command, but GRIT
	// already handles GPU device injection via CDI/bind-mounts, so we can use runc directly.
	checkpointPath := s.opts.ImagePath
	pidFile := s.opts.PidFile
	log.G(ctx).Infof("GPU restore: checkpoint path %s, pidFile %s, bundle %s", checkpointPath, pidFile, p.Bundle)

	// Get the NEW pod UID from OCI config annotations
	configJSONPath := p.Bundle + "/config.json"
	var newPodUID string

	if configData, err := os.ReadFile(configJSONPath); err == nil {
		var config map[string]interface{}
		if err := json.Unmarshal(configData, &config); err == nil {
			annotations, ok := config["annotations"].(map[string]interface{})
			if ok {
				// Log all annotations for debugging
				var annotationKeys []string
				for k := range annotations {
					annotationKeys = append(annotationKeys, k)
				}
				log.G(ctx).Infof("GPU restore: found %d annotations: %v", len(annotations), annotationKeys)

				if uid, ok := annotations["io.kubernetes.pod.uid"].(string); ok {
					newPodUID = uid
					log.G(ctx).Infof("GPU restore: NEW pod UID from annotations: %s", newPodUID)
				} else {
					log.G(ctx).Warnf("GPU restore: io.kubernetes.pod.uid annotation NOT FOUND")
				}
			} else {
				log.G(ctx).Warnf("GPU restore: no annotations block in config.json")
			}
		} else {
			log.G(ctx).Warnf("GPU restore: failed to parse config.json: %v", err)
		}
	} else {
		log.G(ctx).Warnf("GPU restore: failed to read config.json: %v", err)
	}

	// If annotation not found, try to find new pod UID from the OCI config mounts
	// The new pod's volumes will be mounted from /var/lib/kubelet/pods/NEW_UID/...
	if newPodUID == "" {
		if configData, err := os.ReadFile(configJSONPath); err == nil {
			// Look for kubelet paths in the mounts
			podUIDInMounts := regexp.MustCompile(`/var/lib/kubelet/pods/([a-f0-9-]{36})/`)
			matches := podUIDInMounts.FindAllStringSubmatch(string(configData), -1)
			for _, match := range matches {
				if len(match) > 1 {
					newPodUID = match[1]
					log.G(ctx).Infof("GPU restore: found NEW pod UID from OCI config mounts: %s", newPodUID)
					break
				}
			}
		}
	}

	// Find the mountpoints image file (suffix varies, e.g., mountpoints-12.img, mountpoints-13.img)
	var mountpointsFile string
	if files, err := os.ReadDir(checkpointPath); err == nil {
		for _, f := range files {
			if strings.HasPrefix(f.Name(), "mountpoints-") && strings.HasSuffix(f.Name(), ".img") {
				mountpointsFile = filepath.Join(checkpointPath, f.Name())
				log.G(ctx).Infof("GPU restore: found mountpoints file: %s", mountpointsFile)
				break
			}
		}
	}

	// Use crit to decode the checkpoint mountpoints and find ALL kubelet-managed paths
	// Then create symlinks from OLD pod paths to NEW pod paths
	var critOutput []byte
	var critErr error
	if mountpointsFile != "" {
		crit := exec.CommandContext(ctx, "crit", "decode", "-i", mountpointsFile, "--pretty")
		critOutput, critErr = crit.CombinedOutput()
	} else {
		critErr = fmt.Errorf("no mountpoints file found")
	}

	if critErr == nil && newPodUID != "" {
		processedPaths := make(map[string]bool)

		// === PART 1: Handle kubelet pod paths ===
		kubeletPathPattern := regexp.MustCompile(`/var/lib/kubelet/pods/([a-f0-9-]{36})/([^"'\s,]+)`)
		kubeletMatches := kubeletPathPattern.FindAllStringSubmatch(string(critOutput), -1)

		var oldPodUID string
		for _, match := range kubeletMatches {
			if len(match) >= 2 && match[1] != newPodUID {
				oldPodUID = match[1]
				break
			}
		}

		if oldPodUID != "" {
			log.G(ctx).Infof("GPU restore: remapping kubelet paths from OLD pod %s to NEW pod %s", oldPodUID, newPodUID)

			// Build projected volume mapping
			projectedVolumeMap := make(map[string]string)
			newProjectedPath := filepath.Join("/var/lib/kubelet/pods", newPodUID, "volumes/kubernetes.io~projected")
			if entries, err := os.ReadDir(newProjectedPath); err == nil && len(entries) > 0 {
				for _, match := range kubeletMatches {
					if len(match) >= 3 && strings.HasPrefix(match[2], "volumes/kubernetes.io~projected/") {
						parts := strings.Split(match[2], "/")
						if len(parts) >= 3 {
							oldVolName := strings.TrimSuffix(parts[2], "/")
							projectedVolumeMap[oldVolName] = entries[0].Name()
						}
					}
				}
			}

			// Build container hash mapping - find actual hashes in new container dirs
			containerHashMap := make(map[string]string) // "containers/cuda/OLDHASH" -> "containers/cuda/NEWHASH"
			newContainersPath := filepath.Join("/var/lib/kubelet/pods", newPodUID, "containers")
			if containerDirs, err := os.ReadDir(newContainersPath); err == nil {
				for _, containerDir := range containerDirs {
					if containerDir.IsDir() {
						// Find actual hash directories inside new container
						containerPath := filepath.Join(newContainersPath, containerDir.Name())
						if hashDirs, err := os.ReadDir(containerPath); err == nil && len(hashDirs) > 0 {
							newHash := hashDirs[0].Name()
							// Map old container paths to new ones
							for _, match := range kubeletMatches {
								if len(match) >= 3 && strings.HasPrefix(match[2], "containers/") {
									parts := strings.Split(match[2], "/")
									if len(parts) >= 3 && parts[1] == containerDir.Name() {
										oldKey := fmt.Sprintf("containers/%s/%s", parts[1], parts[2])
										newKey := fmt.Sprintf("containers/%s/%s", containerDir.Name(), newHash)
										containerHashMap[oldKey] = newKey
										log.G(ctx).Infof("GPU restore: mapping container path %s -> %s", oldKey, newKey)
									}
								}
							}
						}
					}
				}
			}

			// Create symlinks for kubelet paths
			for _, match := range kubeletMatches {
				if len(match) < 3 || match[1] != oldPodUID {
					continue
				}

				subPath := strings.TrimSuffix(match[2], "/")
				oldPath := filepath.Join("/var/lib/kubelet/pods", oldPodUID, subPath)

				if processedPaths[oldPath] {
					continue
				}
				processedPaths[oldPath] = true

				var newPath string

				if strings.HasPrefix(subPath, "volumes/kubernetes.io~projected/") {
					parts := strings.Split(subPath, "/")
					if len(parts) >= 3 {
						if newVolName, ok := projectedVolumeMap[parts[2]]; ok {
							newPath = filepath.Join("/var/lib/kubelet/pods", newPodUID, "volumes/kubernetes.io~projected", newVolName)
						}
					}
				} else if strings.HasPrefix(subPath, "containers/") {
					// Use the hash mapping
					parts := strings.Split(subPath, "/")
					if len(parts) >= 3 {
						oldKey := fmt.Sprintf("containers/%s/%s", parts[1], parts[2])
						if newKey, ok := containerHashMap[oldKey]; ok {
							newPath = filepath.Join("/var/lib/kubelet/pods", newPodUID, newKey)
						}
					}
				} else {
					// Direct mapping (etc-hosts, etc.)
					newPath = filepath.Join("/var/lib/kubelet/pods", newPodUID, subPath)
				}

				if newPath != "" {
					if _, err := os.Stat(newPath); err != nil {
						log.G(ctx).Warnf("GPU restore: new kubelet path doesn't exist, skipping: %s", newPath)
						continue
					}

					parentDir := filepath.Dir(oldPath)
					if err := os.MkdirAll(parentDir, 0755); err != nil {
						log.G(ctx).Warnf("GPU restore: failed to create dir %s: %v", parentDir, err)
						continue
					}

					os.Remove(oldPath)
					if err := os.Symlink(newPath, oldPath); err != nil {
						log.G(ctx).Warnf("GPU restore: failed to create symlink %s -> %s: %v", oldPath, newPath, err)
					} else {
						log.G(ctx).Infof("GPU restore: created symlink %s -> %s", oldPath, newPath)
					}
				}
			}
		}

		// === PART 2: Handle containerd sandbox paths (/etc/hostname, /etc/resolv.conf) ===
		// These come from: /var/lib/containerd/io.containerd.grpc.v1.cri/sandboxes/SANDBOX_ID/...
		sandboxPathPattern := regexp.MustCompile(`/var/lib/containerd/[^/]+/sandboxes/([a-f0-9]+)/([^"'\s,]+)`)
		sandboxMatches := sandboxPathPattern.FindAllStringSubmatch(string(critOutput), -1)

		// Get the NEW sandbox ID from the bundle path (it contains the sandbox ID)
		var newSandboxID string
		bundleSandboxPattern := regexp.MustCompile(`/run/containerd/[^/]+/k8s.io/([a-f0-9]+)`)
		if bundleMatch := bundleSandboxPattern.FindStringSubmatch(p.Bundle); len(bundleMatch) >= 2 {
			newSandboxID = bundleMatch[1]
		}

		// Also try to find sandbox from OCI config
		if newSandboxID == "" {
			if configData, err := os.ReadFile(configJSONPath); err == nil {
				sandboxIDPattern := regexp.MustCompile(`"io\.kubernetes\.cri\.sandbox-id"\s*:\s*"([a-f0-9]+)"`)
				if match := sandboxIDPattern.FindSubmatch(configData); len(match) >= 2 {
					newSandboxID = string(match[1])
				}
			}
		}

		if newSandboxID != "" && len(sandboxMatches) > 0 {
			log.G(ctx).Infof("GPU restore: handling containerd sandbox paths, new sandbox: %s", newSandboxID)

			for _, match := range sandboxMatches {
				if len(match) < 3 {
					continue
				}

				oldSandboxID := match[1]
				subPath := strings.TrimSuffix(match[2], "/")
				oldPath := filepath.Join("/var/lib/containerd/io.containerd.grpc.v1.cri/sandboxes", oldSandboxID, subPath)

				if processedPaths[oldPath] || oldSandboxID == newSandboxID {
					continue
				}
				processedPaths[oldPath] = true

				newPath := filepath.Join("/var/lib/containerd/io.containerd.grpc.v1.cri/sandboxes", newSandboxID, subPath)

				if _, err := os.Stat(newPath); err != nil {
					log.G(ctx).Warnf("GPU restore: new sandbox path doesn't exist, skipping: %s", newPath)
					continue
				}

				parentDir := filepath.Dir(oldPath)
				if err := os.MkdirAll(parentDir, 0755); err != nil {
					log.G(ctx).Warnf("GPU restore: failed to create dir %s: %v", parentDir, err)
					continue
				}

				os.Remove(oldPath)
				if err := os.Symlink(newPath, oldPath); err != nil {
					log.G(ctx).Warnf("GPU restore: failed to create sandbox symlink %s -> %s: %v", oldPath, newPath, err)
				} else {
					log.G(ctx).Infof("GPU restore: created sandbox symlink %s -> %s", oldPath, newPath)
				}
			}
		}
	} else {
		log.G(ctx).Warnf("GPU restore: crit decode failed or no new pod UID: %v", critErr)
	}

	// Write CRIU config file
	criuConfigPath := p.Bundle + "/criu-gpu.conf"
	criuConfig := `# CRIU GPU restore configuration
tcp-established
ext-unix-sk
shell-job
ext-mount-map auto
enable-external-masters
enable-external-sharing
mntns-compat-mode
`
	if err := os.WriteFile(criuConfigPath, []byte(criuConfig), 0644); err != nil {
		log.G(ctx).Warnf("GPU restore: failed to write CRIU config: %v", err)
	} else {
		log.G(ctx).Infof("GPU restore: wrote CRIU config to %s", criuConfigPath)
	}

	// Add OCI annotation to config.json so runc reads our CRIU config
	if configData, err := os.ReadFile(configJSONPath); err == nil {
		var config map[string]interface{}
		if err := json.Unmarshal(configData, &config); err == nil {
			annotations, ok := config["annotations"].(map[string]interface{})
			if !ok {
				annotations = make(map[string]interface{})
				config["annotations"] = annotations
			}
			annotations["org.criu.config"] = criuConfigPath
			log.G(ctx).Infof("GPU restore: added org.criu.config annotation pointing to %s", criuConfigPath)

			if modifiedConfig, err := json.MarshalIndent(config, "", "  "); err == nil {
				if err := os.WriteFile(configJSONPath, modifiedConfig, 0644); err != nil {
					log.G(ctx).Warnf("GPU restore: failed to write modified config.json: %v", err)
				} else {
					log.G(ctx).Infof("GPU restore: updated config.json with CRIU annotation")
				}
			}
		}
	}

	// Call runc directly - bypasses nvidia-container-runtime which doesn't support restore
	runcArgs := []string{
		"restore",
		"--image-path", checkpointPath,
		"--bundle", p.Bundle,
		"--detach",
		"--pid-file", pidFile,
		"--manage-cgroups-mode", "ignore",
		p.id,
	}
	log.G(ctx).Infof("GPU restore: calling runc directly with args: %v", runcArgs)

	cmd := exec.CommandContext(ctx, "/usr/bin/runc", runcArgs...)
	cmd.Dir = p.Bundle

	output, err := cmd.CombinedOutput()
	if err != nil {
		log.G(ctx).Errorf("GPU restore: runc restore failed: %v, output: %s", err, string(output))
		return p.runtimeError(err, "OCI runtime restore failed")
	}
	log.G(ctx).Infof("GPU restore: runc restore succeeded, output: %s", string(output))

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
	case "paused":
		s.p.initState = &pausedState{p: s.p}
	default:
		return fmt.Errorf("invalid state transition %q to %q", stateName(s), name)
	}
	return nil
}

func (s *runningState) Pause(ctx context.Context) error {
	s.p.pausing.Store(true)
	// NOTE "pausing" will be returned in the short window
	// after `transition("paused")`, before `pausing` is reset
	// to false. That doesn't break the state machine, just
	// delays the "paused" state a little bit.
	defer s.p.pausing.Store(false)

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
	s.p.setExited(status)

	if err := s.p.runtime.Resume(context.Background(), s.p.id); err != nil {
		log.L.WithError(err).Error("resuming exited container from paused state")
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
