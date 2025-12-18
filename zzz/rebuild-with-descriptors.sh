#!/bin/bash
# Rebuild grit-agent with descriptors.json fix

set -e

echo "=== Step 1: Copy updated runtime.go to server ==="
cd /tmp
rm -rf /tmp/grit-build 2>/dev/null || true
mkdir -p /tmp/grit-build

# Copy updated source from local
cat > /tmp/grit-build/runtime.go << 'GOSOURCE'
// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.

package checkpoint

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path"
	"sort"
	"strconv"
	"strings"
	"time"

	crmetadata "github.com/checkpoint-restore/checkpointctl/lib"
	containerd "github.com/containerd/containerd/v2/client"
	"github.com/containerd/containerd/v2/core/content"
	"github.com/containerd/containerd/v2/core/diff"
	"github.com/containerd/containerd/v2/pkg/namespaces"
	"github.com/containerd/containerd/v2/pkg/rootfs"
	"go.opentelemetry.io/otel/trace"
	"go.opentelemetry.io/otel/trace/noop"
	internalapi "k8s.io/cri-api/pkg/apis"
	runtimeapi "k8s.io/cri-api/pkg/apis/runtime/v1"
	remote "k8s.io/cri-client/pkg"
	"k8s.io/klog/v2"
	"sigs.k8s.io/controller-runtime/pkg/log"

	"github.com/kaito-project/grit/cmd/grit-agent/app/options"
	"github.com/kaito-project/grit/pkg/metadata"
)

func RuntimeCheckpointPod(ctx context.Context, opts *options.RuntimeCheckpointOptions) error {
	criClient, err := getRuntimeService(ctx, opts)
	if err != nil {
		return fmt.Errorf("failed to get runtime service: %w", err)
	}
	ctrClient, err := getContainerdClient(ctx, opts)
	if err != nil {
		return fmt.Errorf("failed to get containerd client: %w", err)
	}
	defer ctrClient.Close()

	// find containers
	containers, err := criClient.ListContainers(ctx, &runtimeapi.ContainerFilter{
		LabelSelector: map[string]string{
			"io.kubernetes.pod.name":      opts.TargetPodName,
			"io.kubernetes.pod.namespace": opts.TargetPodNamespace,
		},
		State: &runtimeapi.ContainerStateValue{
			State: runtimeapi.ContainerState_CONTAINER_RUNNING,
		},
	})
	if err != nil {
		return fmt.Errorf("failed to list containers: %w", err)
	}
	if len(containers) == 0 {
		return fmt.Errorf("no containers found for pod %s/%s", opts.TargetPodNamespace, opts.TargetPodName)
	}

	// checkpoint each container
	for _, container := range containers {
		if err := runtimeCheckpointContainer(ctx, container, ctrClient, opts); err != nil {
			return fmt.Errorf("failed to checkpoint container %s: %w", container.Id, err)
		}
	}

	return nil
}

func getRuntimeService(ctx context.Context, opts *options.RuntimeCheckpointOptions) (internalapi.RuntimeService, error) {
	logger := klog.Background()

	var tp trace.TracerProvider = noop.NewTracerProvider()
	timeout := time.Second * 10

	return remote.NewRemoteRuntimeService(opts.RuntimeEndpoint, timeout, tp, &logger)
}

func getContainerdClient(ctx context.Context, opts *options.RuntimeCheckpointOptions) (*containerd.Client, error) {
	ctrOpts := []containerd.Opt{
		containerd.WithTimeout(10 * time.Second),
	}

	return containerd.New(opts.RuntimeEndpoint, ctrOpts...)
}

func runtimeCheckpointContainer(ctx context.Context, ctrmeta *runtimeapi.Container, client *containerd.Client, opts *options.RuntimeCheckpointOptions) error {
	workPath := path.Join(opts.HostWorkPath, ctrmeta.GetMetadata().GetName()+"-work")
	logger := log.FromContext(ctx).WithValues("container", ctrmeta.Id, "workPath", workPath)
	ctx = log.IntoContext(ctx, logger)
	if err := os.MkdirAll(workPath, 0755); err != nil {
		return fmt.Errorf("failed to create work path %s: %w", workPath, err)
	}

	logger.Info("Checkpointing container", "step", "pause container")
	ctx = namespaces.WithNamespace(ctx, "k8s.io")
	container, err := client.LoadContainer(ctx, ctrmeta.Id)
	if err != nil {
		return fmt.Errorf("failed to load container %s: %w", ctrmeta.Id, err)
	}
	task, err := container.Task(ctx, nil)
	if err != nil {
		return err
	}
	_ = task

	logger.Info("Checkpointing container", "step", "criu dump")
	checkpointPath := path.Join(workPath, crmetadata.CheckpointDirectory)
	if err := writeCriuCheckpoint(ctx, task, checkpointPath, workPath); err != nil {
		return fmt.Errorf("failed to write criu checkpoint: %w", err)
	}

	logger.Info("Checkpointing container", "step", "write rootfs diff")
	rootFsDiffTarPath := path.Join(workPath, crmetadata.RootFsDiffTar)
	if err := writeRootFsDiffTar(ctx, ctrmeta, client, rootFsDiffTarPath); err != nil {
		return fmt.Errorf("failed to write rootfs diff tar: %w", err)
	}

	logger.Info("Checkpointing container", "step", "save container logs")
	containerLogPath := path.Join(getPodLogPath(opts), ctrmeta.GetMetadata().GetName())
	savePath := path.Join(workPath, metadata.ContainerLogFile)
	if err := writeContainerLog(ctx, containerLogPath, savePath); err != nil {
		logger.Info("Failed to save container log", "error", err)
	}

	logger.Info("Checkpointing container", "step", "rename work path")
	checkpointDir := path.Join(opts.HostWorkPath, ctrmeta.GetMetadata().GetName())
	if err := os.Rename(workPath, checkpointDir); err != nil {
		return fmt.Errorf("failed to rename work path %s to checkpoint path %s: %w", workPath, checkpointDir, err)
	}

	logger.Info("Checkpointing container successfully")

	return nil
}

func writeCriuCheckpoint(ctx context.Context, task containerd.Task, checkpointPath, criuWorkPath string) error {
	if err := os.MkdirAll(checkpointPath, 0755); err != nil {
		return fmt.Errorf("failed to create checkpoint path %s: %w", checkpointPath, err)
	}

	pid := task.Pid()
	if pid == 0 {
		return fmt.Errorf("task %s has no PID", task.ID())
	}

	log.FromContext(ctx).Info("Pre-fixing mount propagation for shared mounts", "pid", pid)
	
	findMountsCmd := exec.Command("awk", "$0 ~ /master:/ {print $5}", fmt.Sprintf("/proc/%d/mountinfo", pid))
	mountsOutput, _ := findMountsCmd.Output()
	mounts := strings.Split(strings.TrimSpace(string(mountsOutput)), "\n")
	
	fixedCount := 0
	for _, mount := range mounts {
		mount = strings.TrimSpace(mount)
		if mount == "" {
			continue
		}
		log.FromContext(ctx).Info("Fixing shared mount", "mount", mount, "pid", pid)
		fixCmd := exec.Command("nsenter", "-t", strconv.Itoa(int(pid)), "-m", "--", "mount", "--make-private", mount)
		if output, err := fixCmd.CombinedOutput(); err != nil {
			log.FromContext(ctx).Info("Mount fix error (continuing)", "mount", mount, "error", err, "output", string(output))
		} else {
			fixedCount++
		}
	}
	log.FromContext(ctx).Info("Mount fixes completed", "fixed", fixedCount, "total", len(mounts))

	log.FromContext(ctx).Info("Locking CUDA state", "pid", pid)
	cudaLock := exec.Command("/usr/local/cuda/bin/cuda-checkpoint", "--action", "lock", "--pid", strconv.Itoa(int(pid)))
	if output, err := cudaLock.CombinedOutput(); err != nil {
		log.FromContext(ctx).Info("CUDA lock error (continuing)", "error", err, "output", string(output))
	}
	
	log.FromContext(ctx).Info("Checkpointing CUDA state", "pid", pid)
	cudaCkpt := exec.Command("/usr/local/cuda/bin/cuda-checkpoint", "--action", "checkpoint", "--pid", strconv.Itoa(int(pid)))
	if output, err := cudaCkpt.CombinedOutput(); err != nil {
		log.FromContext(ctx).Info("CUDA checkpoint error (continuing)", "error", err, "output", string(output))
	}

	criuArgs := []string{
		"-t", "1",
		"-m", "--",
		"/usr/local/bin/criu.real",
		"dump",
		"-t", strconv.Itoa(int(pid)),
		"-D", checkpointPath,
		"-v4",
		"--log-file", path.Join(checkpointPath, "dump.log"),
		"--external", "mnt[]",
		"--force-irmap",
		"--shell-job",
		"--tcp-established",
		"--ext-unix-sk",
	}

	cmd := exec.Command("nsenter", criuArgs...)
	cmd.Dir = criuWorkPath

	output, err := cmd.CombinedOutput()
	if err != nil {
		log.FromContext(ctx).Error(err, "CRIU dump failed",
			"pid", pid,
			"output", string(output),
			"checkpointPath", checkpointPath)
		return fmt.Errorf("failed to checkpoint task %s: %w\nOutput: %s", task.ID(), err, string(output))
	}

	log.FromContext(ctx).Info("CRIU checkpoint completed",
		"pid", pid,
		"path", checkpointPath,
		"taskID", task.ID())

	// Create descriptors.json - required by runc restore
	descriptorsPath := path.Join(checkpointPath, "descriptors.json")
	if err := os.WriteFile(descriptorsPath, []byte("[]"), 0644); err != nil {
		log.FromContext(ctx).Error(err, "Failed to create descriptors.json", "path", descriptorsPath)
		return fmt.Errorf("failed to create descriptors.json: %w", err)
	}
	log.FromContext(ctx).Info("Created descriptors.json", "path", descriptorsPath)

	return nil
}

func writeRootFsDiffTar(ctx context.Context, ctrmeta *runtimeapi.Container, client *containerd.Client, path string) error {
	c, err := client.ContainerService().Get(ctx, ctrmeta.Id)
	if err != nil {
		return fmt.Errorf("failed to get container %s: %w", ctrmeta.Id, err)
	}
	diffOpts := []diff.Opt{
		diff.WithReference(fmt.Sprintf("checkpoint-rw-%s", c.SnapshotKey)),
	}
	rw, err := rootfs.CreateDiff(ctx,
		c.SnapshotKey,
		client.SnapshotService(c.Snapshotter),
		client.DiffService(),
		diffOpts...,
	)
	if err != nil {
		return fmt.Errorf("failed to create diff for container %s: %w", ctrmeta.Id, err)
	}

	ra, err := client.ContentStore().ReaderAt(ctx, rw)
	if err != nil {
		return fmt.Errorf("failed to get reader for diff %v: %w", rw, err)
	}
	defer ra.Close()

	f, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("failed to create file %s: %w", path, err)
	}
	defer f.Close()

	_, err = io.Copy(f, content.NewReader(ra))
	if err != nil {
		return fmt.Errorf("failed to copy diff to file %s: %w", path, err)
	}
	return nil
}

func getPodLogPath(opts *options.RuntimeCheckpointOptions) string {
	return path.Join(opts.KubeletLogPath, fmt.Sprintf("%s_%s_%s", opts.TargetPodNamespace, opts.TargetPodName, opts.TargetPodUID))
}

func writeContainerLog(ctx context.Context, logdir, savePath string) error {
	files, err := os.ReadDir(logdir)
	if err != nil {
		return fmt.Errorf("failed to read log directory %s: %w", logdir, err)
	}

	var logFiles []string
	for _, file := range files {
		if file.IsDir() {
			continue
		}
		if path.Ext(file.Name()) == ".log" {
			logFiles = append(logFiles, file.Name())
		}
	}

	if len(logFiles) == 0 {
		log.FromContext(ctx).Info("No log files found, Skip")
		return nil
	}

	sort.Strings(logFiles)

	srcPath := path.Join(logdir, logFiles[len(logFiles)-1])
	log.FromContext(ctx).Info("Save log", "file", srcPath)
	srcFile, err := os.Open(srcPath)
	if err != nil {
		return fmt.Errorf("failed to open log file %s: %w", srcPath, err)
	}
	defer srcFile.Close()

	destFile, err := os.Create(savePath)
	if err != nil {
		return fmt.Errorf("failed to create destination file %s: %w", savePath, err)
	}
	defer destFile.Close()

	if _, err := io.Copy(destFile, srcFile); err != nil {
		return fmt.Errorf("failed to copy log file to %s: %w", savePath, err)
	}

	return nil
}
GOSOURCE

echo "=== Step 2: Build grit-agent binary ==="
cd /tmp/grit-build

# Clone GRIT repo for building
git clone --depth 1 https://github.com/kaito-project/grit.git grit-src 2>/dev/null || true
cd grit-src

# Copy updated runtime.go
cp /tmp/grit-build/runtime.go pkg/gritagent/checkpoint/runtime.go

# Build
export PATH=/usr/local/go/bin:$PATH
export GOROOT=/usr/local/go
go build -o /tmp/grit-build/grit-agent ./cmd/grit-agent

echo "=== Step 3: Build Docker image ==="
cd /tmp/grit-build

cat > Dockerfile << 'DOCKERFILE'
FROM debian:bookworm-slim

# Install dependencies
RUN apt-get update && apt-get install -y \
    libbsd0 libnet1 libnl-3-200 libprotobuf-c1 \
    iptables procps gawk util-linux \
    && rm -rf /var/lib/apt/lists/*

# Copy grit-agent binary
COPY grit-agent /grit-agent
RUN mkdir -p /usr/local/bin && cp /grit-agent /usr/local/bin/grit-agent
RUN chmod +x /grit-agent /usr/local/bin/grit-agent

ENTRYPOINT ["/usr/local/bin/grit-agent"]
DOCKERFILE

sudo docker build --no-cache -t grit-agent:gpu-fix .

echo "=== Step 4: Import to containerd ==="
sudo docker save grit-agent:gpu-fix | sudo /var/lib/rancher/k3s/data/current/bin/ctr -n k8s.io images import -

echo "=== Step 5: Verify ==="
sudo /var/lib/rancher/k3s/data/current/bin/ctr -n k8s.io images ls | grep grit-agent

echo ""
echo "=== Done! Now delete old checkpoint and test again ==="
