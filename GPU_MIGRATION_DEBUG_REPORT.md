# GRIT GPU Pod Migration - Debug Report

**Date:** December 16, 2025  
**Status:** CRIU Checkpoint works, CRIU Restore NOT working  
**Environment:** K3s on Ubuntu 22.04, NVIDIA A10 GPUs

---

## Executive Summary

GPU pod migration with GRIT partially works:
- ✅ GPU state freezing with `cuda-checkpoint` works
- ✅ CRIU checkpoint creation works (non-empty checkpoint files)
- ✅ Checkpoint/Restore CRs are created and marked complete
- ❌ **CRIU restore does NOT happen** - process starts fresh instead of resuming

---

## The Problem

### Observed Behavior

When running the migration test:

| Metric | Source (before checkpoint) | Destination (after "restore") |
|--------|---------------------------|------------------------------|
| Loss value | `-34046.9844` | `-11774.5762` ← **DIFFERENT** |
| Training steps | 10, 20, 30 | 10, 20, 30, 40 ← **Restarts from 10** |

The process is **starting fresh** on the destination node, not resuming from the checkpointed state.

### Evidence

1. **Loss values differ** - If CRIU restored the process, the random tensors and computed loss would be identical
2. **Steps restart from 10** - Should continue from step 31+
3. **runc-grit wrapper log** only shows `--version` calls, no `restore` operations:
   ```
   [Tue Dec 16 06:38:25 UTC 2025] runc-grit: --version
   ```
4. **No GPU restore log** - The action script for `cuda-checkpoint --action restore` was never invoked

---

## Root Cause Analysis

### The Architecture Gap

The current GRIT restore flow has a fundamental issue:

**Checkpoint Flow (WORKS):**
1. `migrate.sh` calls `cuda-checkpoint --action lock` then `--action checkpoint` to freeze GPU state
2. Creates a `Checkpoint` CR
3. `grit-manager` spawns a `grit-agent` Job
4. `grit-agent` calls containerd's `task.Checkpoint()` API
5. CRIU saves process memory, registers, file descriptors to disk
6. Checkpoint CR marked "Checkpointed"

**Restore Flow (BROKEN):**
1. Creates a `Restore` CR pointing to the checkpoint
2. `migrate.sh` creates a **NEW pod** with:
   ```yaml
   command: ["python3", "-u", "/workspace/train.py"]
   ```
3. Kubernetes/containerd starts a **fresh Python process**
4. Restore CR is marked "Restored" but **no actual CRIU restore happens**
5. The `runc-grit` wrapper is never called with a `restore` operation

### Why CRIU Restore Isn't Triggered

The `Restore` CR and restore pod are disconnected:
- The restore pod has a `command:` that starts a fresh process
- The GRIT shim doesn't intercept this to perform CRIU restore
- `runc create` is called (starts new process) instead of `runc restore` (resumes from checkpoint)

### What Should Happen

For true CRIU restore:
1. Shim detects this container is associated with a Restore CR
2. Instead of `runc create`, shim calls `runc restore --image-path=/checkpoint/path`
3. CRIU recreates exact process state from checkpoint images
4. `cuda-checkpoint --action restore` reattaches GPU memory to restored process

---

## What We Tried

### 1. Initial cuda-checkpoint Timing Issue

**Problem:** `cuda-checkpoint --action restore` was being called before CRIU restored the process.

**Attempted Fix:** Implement `runc-grit` wrapper (Option 2) to hook into runc's restore flow and call `cuda-checkpoint` at the right time via CRIU action scripts.

**Result:** Wrapper deployed but never invoked for restore operations.

### 2. Empty Checkpoint Files

**Problem:** `grit-agent` was creating 0-byte checkpoint files.

**Root Cause:** The `task.Checkpoint()` API call wasn't passing `CheckpointOptions` with `ImagePath`.

**Fix Applied:** Modified `pkg/gritagent/checkpoint/runtime.go`:

```go
func writeCriuCheckpoint(ctx context.Context, task containerd.Task, checkpointPath, criuWorkPath string) error {
    if err := os.MkdirAll(checkpointPath, 0755); err != nil {
        return fmt.Errorf("failed to create checkpoint path %s: %w", checkpointPath, err)
    }

    checkpointOpts := &runcoptions.CheckpointOptions{
        ImagePath:           checkpointPath,  // CRITICAL - was missing
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

    _, err := task.Checkpoint(ctx, opts...)
    if err != nil {
        return fmt.Errorf("failed to checkpoint task %s: %w", task.ID(), err)
    }
    return nil
}
```

**Result:** Checkpoint files are now created with actual data. ✅

### 3. K3s Containerd Config Regeneration

**Problem:** K3s regenerates `/var/lib/rancher/k3s/agent/etc/containerd/config.toml` on restart, overwriting our `grit` runtime configuration.

**Attempted Fix:** Created Python scripts to fix both the config and the template:
- `fix_grit_config.py` - Removes problematic `[options]` section
- `fix_dest_template.py` - Fixes `config.toml.tmpl` to persist across restarts

**Result:** Configuration stays correct after K3s restart. ✅

### 4. GRIT Shim Runtime Options Parsing

**Problem:** Shim crashed with `type with url : not found` when K3s injected unknown runtime options.

**Fix Applied:** Modified `cmd/containerd-shim-grit-v1/runc/container.go`:

```go
func readRuntimeOptions(r *task.CreateTaskRequest) (*options.Options, error) {
    opts := &options.Options{}
    if r.Options == nil {
        return opts, nil
    }

    v, err := typeurl.UnmarshalAny(r.Options)
    if err != nil {
        // Gracefully handle unknown options - use defaults
        return opts, nil
    }
    // ... rest of function
}

func newInit(...) (*process.Init, error) {
    binaryName := options.BinaryName
    if binaryName == "" {
        binaryName = "nvidia-container-runtime"  // Default for GPU support
    }
    // ...
}
```

**Result:** Shim no longer crashes on unknown options. ✅

### 5. Image Pull Issues

**Problem:** `grit-agent` pod stuck in `ImagePullBackOff` or `ErrImageNeverPull`.

**Fix Applied:** 
- Import images directly to K3s containerd: `docker save | sudo k3s ctr images import -`
- Update ConfigMap to use `imagePullPolicy: Never` for local images

**Result:** Images load correctly from local containerd. ✅

### 6. Containerd Socket Path for K3s

**Problem:** `grit-agent` couldn't connect to containerd - wrong socket path.

**Fix Applied:** Made socket path configurable in Helm chart:
- Added `runtimeSocket` to `values.yaml`
- Updated `grit-agent-config.yaml` template to use `/run/k3s/containerd/containerd.sock`

**Result:** Agent connects to K3s containerd correctly. ✅

### 7. runc-grit Wrapper for GPU Restore

**Problem:** Need to call `cuda-checkpoint --action restore` after CRIU restores the process.

**Implementation:** Created `/usr/local/bin/runc-grit` wrapper:

```bash
#!/bin/bash
LOG="/var/log/runc-grit.log"
REAL_RUNC="/usr/bin/runc"

echo "[$(date)] runc-grit: $*" >> "$LOG"

if [[ "$1" == "restore" ]]; then
    # Find checkpoint path and set up CRIU action script
    for i in "${!args[@]}"; do
        if [[ "${args[$i]}" == "--image-path" ]]; then
            CHECKPOINT_PATH="${args[$i+1]}"
            # Create action script for post-restore GPU reattachment
            # ...
        fi
    done
fi

exec "$REAL_RUNC" "$@"
```

**Result:** Wrapper installed but never called with `restore` - the restore flow doesn't use CRIU. ❌

---

## Current State

### What Works
1. GPU training pod deploys and runs on source node
2. `cuda-checkpoint` freezes GPU state correctly
3. GRIT Checkpoint CR is created and completes
4. CRIU checkpoint files are created with actual process data
5. Source pod is deleted
6. Restore CR is created
7. New pod starts on destination node
8. GPU is in "running" state (but for a NEW process)

### What Doesn't Work
1. **CRIU restore is never invoked** - `runc restore` is not called
2. **Process starts fresh** - Different loss values, steps restart
3. **runc-grit wrapper** is not used for restore operations

---

## How to Reproduce

### Prerequisites

- 2 Linux nodes with NVIDIA GPUs (Ubuntu 22.04 recommended)
- K3s installed on both nodes (or standard Kubernetes with containerd)
- SSH access between nodes
- NVIDIA drivers + nvidia-container-toolkit installed

### Step 1: Clone and Build

```bash
git clone https://github.com/YOUR_FORK/grit.git
cd grit

# Build components
docker build -t containerd-shim-grit-v1:latest -f docker/containerd-shim-grit-v1/Dockerfile .
docker build --no-cache -t grit-agent:fix-checkpoint -f docker/grit-agent/Dockerfile .
docker build -t grit-manager:latest -f docker/grit-manager/Dockerfile .
```

### Step 2: Deploy to Nodes

On each GPU node:

```bash
# Import images
docker save containerd-shim-grit-v1:latest | ssh ubuntu@NODE_IP "sudo k3s ctr images import -"
docker save grit-agent:fix-checkpoint | ssh ubuntu@NODE_IP "sudo k3s ctr images import -"
docker save grit-manager:latest | ssh ubuntu@NODE_IP "sudo k3s ctr images import -"

# Install shim binary
ssh ubuntu@NODE_IP "sudo cp /path/to/containerd-shim-grit-v1 /usr/local/bin/"
```

### Step 3: Configure Containerd

Edit `/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl` on each node:

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.grit]
  runtime_type = "io.containerd.grit.v1"
```

Restart K3s:
```bash
sudo systemctl restart k3s  # or k3s-agent on worker nodes
```

### Step 4: Create RuntimeClass

```bash
kubectl apply -f - <<EOF
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: grit
handler: grit
EOF
```

### Step 5: Deploy GRIT Manager

```bash
cd charts/grit-manager
helm install grit-manager . -n grit-system --create-namespace \
  --set runtimeSocket=/run/k3s/containerd/containerd.sock
```

### Step 6: Update ConfigMap for Local Images

```bash
kubectl get cm grit-agent-config -n grit-system -o yaml | \
  sed 's|image:.*grit-agent.*|image: docker.io/library/grit-agent:fix-checkpoint|g' | \
  sed 's|imagePullPolicy: IfNotPresent|imagePullPolicy: Never|g' | \
  kubectl apply -f -
```

### Step 7: Build Test Container

On each node:

```bash
cat > /tmp/Dockerfile.pytorch-criu <<'EOF'
FROM nvcr.io/nvidia/pytorch:23.10-py3
RUN apt-get update && apt-get install -y criu && rm -rf /var/lib/apt/lists/*
EOF

docker build -t pytorch-criu:latest -f /tmp/Dockerfile.pytorch-criu .
docker save pytorch-criu:latest | ssh ubuntu@NODE_IP "sudo k3s ctr images import -"
```

### Step 8: Run Migration Test

Edit `test/migrate.sh`:
- Set `SOURCE_HOST` to your source node IP
- Set `DEST_HOST` to your destination node IP

```bash
cd test
./migrate.sh --deploy --verbose
```

### Expected Error State

The migration will "complete successfully" but:
- Loss values will be **different** before/after migration
- Step counter will **restart from 10**, not continue from checkpoint step
- `runc-grit` wrapper log (`/var/log/runc-grit.log`) will only show `--version` calls

---

## What Needs to be Fixed

### Option A: Modify GRIT Shim to Intercept Restore

The GRIT shim (`containerd-shim-grit-v1`) needs to:

1. Detect when a container is associated with a `Restore` CR
2. Instead of calling `runc create`, call `runc restore --image-path=<checkpoint>`
3. After CRIU restore, call `cuda-checkpoint --action restore` to reattach GPU

**Challenges:**
- Shim runs at container creation time, before the Restore CR is associated
- Need a way to pass checkpoint path to the shim

### Option B: Use containerd's Native Restore API

Instead of creating a new pod, use containerd's task restore API directly:

```go
task, err := container.NewTask(ctx, cio.NewCreator(cio.WithStdio),
    containerd.WithTaskCheckpoint(checkpoint))
```

**Challenges:**
- Kubernetes doesn't expose this API
- Would require changes to how GRIT orchestrates restore

### Option C: Modify Pod Spec for Restore

Change the restore pod spec to not include a `command:`, and have the shim detect this as a restore signal:

```yaml
spec:
  containers:
  - name: training
    image: pytorch-criu:latest
    # No command - signals this is a restore
    annotations:
      grit.dev/restore-from: "gpu-ckpt-123456"
```

**Challenges:**
- Non-standard Kubernetes behavior
- May conflict with image entrypoint

---

## Files Modified During Debugging

| File | Change |
|------|--------|
| `pkg/gritagent/checkpoint/runtime.go` | Fixed `CheckpointOptions` with `ImagePath` |
| `cmd/containerd-shim-grit-v1/runc/container.go` | Graceful options parsing, default runtime |
| `charts/grit-manager/values.yaml` | Added `runtimeSocket` config |
| `charts/grit-manager/templates/grit-agent-config.yaml` | Configurable socket path |
| `charts/grit-manager/templates/grit-manager.yaml` | Removed hardcoded nodeSelector |
| `charts/grit-manager/templates/webhooks-auto-generated.yaml` | Fixed service references |
| `test/migrate.sh` | Full migration test script |
| `test/runc-grit-wrapper.sh` | GPU restore wrapper (not used) |
| `test/fix_grit_config.py` | K3s config cleanup |
| `test/fix_dest_template.py` | K3s template fix |

---

## References

- [CRIU Documentation](https://criu.org/Main_Page)
- [cuda-checkpoint Tool](https://docs.nvidia.com/cuda/cuda-checkpoint/index.html)
- [containerd Checkpoint/Restore](https://github.com/containerd/containerd/blob/main/docs/checkpoint-restore.md)
- [runc restore](https://github.com/opencontainers/runc/blob/main/restore.go)

---

## Contact

For questions about this debug session, refer to the conversation history or contact the repository maintainers.
