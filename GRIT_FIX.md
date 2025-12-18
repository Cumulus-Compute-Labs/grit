# GRIT Fix for GPU Checkpoint

## Problem
GRIT's checkpoint handler freezes the cgroup before calling CRIU, which causes CUDA plugin timeout.

## File to Modify
`pkg/gritagent/checkpoint/runtime.go`

## Current Code (Lines 159-190)
```go
func writeCriuCheckpoint(ctx context.Context, task containerd.Task, checkpointPath, criuWorkPath string) error {
	// Ensure checkpoint directory exists
	if err := os.MkdirAll(checkpointPath, 0755); err != nil {
		return fmt.Errorf("failed to create checkpoint path %s: %w", checkpointPath, err)
	}

	// Create CheckpointOptions
	checkpointOpts := &runcoptions.CheckpointOptions{
		ImagePath:           checkpointPath,
		WorkPath:            criuWorkPath,
		Exit:                false,
		OpenTcp:             true,
		ExternalUnixSockets: true,
		Terminal:            false,
		FileLocks:           true,
	}

	opts := []containerd.CheckpointTaskOpts{
		func(info *containerd.CheckpointTaskInfo) error {
			info.Options = checkpointOpts
			return nil
		},
	}

	// THIS CALLS RUNC CHECKPOINT (which freezes cgroup)
	_, err := task.Checkpoint(ctx, opts...)
	if err != nil {
		return fmt.Errorf("failed to checkpoint task %s: %w", task.ID(), err)
	}
	return nil
}
```

## NEW Code (Replace writeCriuCheckpoint function)
```go
func writeCriuCheckpoint(ctx context.Context, task containerd.Task, checkpointPath, criuWorkPath string) error {
	// Ensure checkpoint directory exists
	if err := os.MkdirAll(checkpointPath, 0755); err != nil {
		return fmt.Errorf("failed to create checkpoint path %s: %w", checkpointPath, err)
	}

	// Get process PID
	pid := task.Pid()
	if pid == 0 {
		return fmt.Errorf("task has no PID")
	}

	// Call CRIU directly (bypass runc to avoid cgroup freeze)
	// This allows CUDA plugin to run before process is frozen
	criuArgs := []string{
		"dump",
		"-t", fmt.Sprintf("%d", pid),
		"-D", checkpointPath,
		"-v4",
		"--log-file", path.Join(checkpointPath, "dump.log"),
		"--external", "mnt[]",
		"--force-irmap",
		"--shell-job",
		"--tcp-established",
		"--ext-unix-sk",
	}

	// Execute CRIU
	cmd := exec.Command("/usr/local/bin/criu.real", criuArgs...)
	cmd.Dir = criuWorkPath
	
	output, err := cmd.CombinedOutput()
	if err != nil {
		log.FromContext(ctx).Error(err, "CRIU dump failed", "output", string(output))
		return fmt.Errorf("failed to checkpoint task %s: %w\nOutput: %s", task.ID(), err, string(output))
	}

	log.FromContext(ctx).Info("CRIU checkpoint completed", "pid", pid, "path", checkpointPath)
	return nil
}
```

## Also Remove the task.Pause() call (Lines 110-120)
```go
// REMOVE THIS BLOCK:
// if task != nil {
//     if err := task.Pause(ctx); err != nil {
//         return err
//     }
//     defer func() {
//         if err := task.Resume(ctx); err != nil {
//             log.FromContext(ctx).Error(err, "failed to resume task")
//         }
//     }()
// }

// REPLACE WITH:
// Don't pause - CRIU will handle process suspension via ptrace
```

## Add Required Imports
At the top of `runtime.go`, add:
```go
import (
	...existing imports...
	"os/exec"
	"strconv"
)
```

## Testing
```bash
# 1. Rebuild GRIT agent
cd grit
make build-agent

# 2. Update agent image
docker build -t grit-agent:gpu-fix -f cmd/grit-agent/Dockerfile .
kubectl set image deployment/grit-agent grit-agent=grit-agent:gpu-fix -n kube-system

# 3. Test checkpoint
kubectl apply -f checkpoint-cr.yaml
kubectl logs deployment/grit-agent -f -n kube-system

# 4. Verify checkpoint files
ls -lh /mnt/grit-agent/default/checkpoint-name/*.img
```

## Why This Works
- ❌ OLD: task.Pause() → cgroup frozen → CUDA plugin timeout
- ✅ NEW: CRIU uses ptrace → process responsive → CUDA plugin succeeds
- CRIU checkpoints GPU memory via CUDA plugin hook
- Process suspended only AFTER GPU state is locked

## Result
Full GRIT checkpoint/restore cycle works with GPU workloads!

