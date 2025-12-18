# GRIT GPU Checkpoint/Restore - Current Status & Future Work

## Summary

This document captures the current state of GPU checkpoint/restore implementation in GRIT, what's working, what's broken, and how to reproduce this setup.

**Date:** December 18, 2025  
**Last Test Result:** Restore completes but GPU memory is not preserved (0MiB after restore)

---

## What's Working

### 1. Checkpoint Phase ✅
- CRIU successfully checkpoints GPU containers using `cuda_plugin.so`
- GPU memory state is captured via `cuda-checkpoint` tool
- Checkpoint files are stored correctly in `/mnt/grit-agent/default/gpu-test-ckpt/cuda/checkpoint/`

### 2. GRIT Shim Modifications ✅
- Bypasses `nvidia-container-runtime` which doesn't support `restore` command
- Calls `/usr/bin/runc restore` directly
- Writes CRIU config with necessary options (`ext-mount-map auto`, `tcp-established`, etc.)
- Adds `org.criu.config` OCI annotation for runc to read CRIU options

### 3. Kubernetes Mount Path Remapping (Partial) ✅
- Successfully remaps **projected volumes** (serviceaccount tokens):
  ```
  /var/lib/kubelet/pods/OLD_UID/volumes/kubernetes.io~projected/kube-api-access-xxx
  → /var/lib/kubelet/pods/NEW_UID/volumes/kubernetes.io~projected/kube-api-access-yyy
  ```
- Successfully remaps **etc-hosts**:
  ```
  /var/lib/kubelet/pods/OLD_UID/etc-hosts
  → /var/lib/kubelet/pods/NEW_UID/etc-hosts
  ```
- Successfully remaps **container termination-log paths** with different hashes:
  ```
  /var/lib/kubelet/pods/OLD_UID/containers/cuda/OLDHASH
  → /var/lib/kubelet/pods/NEW_UID/containers/cuda/NEWHASH
  ```

---

## What's NOT Working

### 1. Containerd Sandbox Paths ❌
The `/etc/hostname` mount comes from containerd sandbox, not kubelet:
```
/var/lib/containerd/io.containerd.grpc.v1.cri/sandboxes/OLD_SANDBOX_ID/hostname
```

**Current Error:**
```
Error (criu/mount.c:2507): mnt: Can't bind-mount at .../etc/hostname: No such file or directory
```

**Root Cause:** The code to handle sandbox paths exists but isn't detecting the new sandbox ID correctly.

**Fix Needed:**
1. Extract new sandbox ID from `io.kubernetes.cri.sandbox-id` annotation
2. Create symlinks for:
   - `/var/lib/containerd/.../sandboxes/OLD_ID/hostname`
   - `/var/lib/containerd/.../sandboxes/OLD_ID/resolv.conf`

### 2. GPU Memory State Not Restored ❌
Even when CRIU restore appears to succeed (on retry), the GPU shows 0MiB memory usage.

**Possible Causes:**
1. CUDA context not being restored correctly
2. `cuda_plugin.so` stage 2 failing (see logs: `cuda_plugin: finished cuda_plugin stage 2 err -1`)
3. Process crashes immediately after restore

**Investigation Needed:**
- Check if the process PID exists after restore
- Check `dmesg` for GPU/CUDA errors
- Verify `cuda-checkpoint` restore phase completes

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Kubernetes                                │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐       │
│  │ Checkpoint  │     │   Restore   │     │  GRIT       │       │
│  │   CRD       │────▶│    CRD      │────▶│  Agent      │       │
│  └─────────────┘     └─────────────┘     └──────┬──────┘       │
└────────────────────────────────────────────────┼───────────────┘
                                                  │
┌────────────────────────────────────────────────▼───────────────┐
│                       containerd                                │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              containerd-shim-grit-v1                     │   │
│  │  ┌─────────────────────────────────────────────────┐    │   │
│  │  │ init_state.go:Start()                            │    │   │
│  │  │  1. Detect restore annotation                    │    │   │
│  │  │  2. Find OLD pod UID from CRIU mountpoints       │    │   │
│  │  │  3. Find NEW pod UID from OCI config             │    │   │
│  │  │  4. Create symlinks OLD → NEW                    │    │   │
│  │  │  5. Write CRIU config file                       │    │   │
│  │  │  6. Call /usr/bin/runc restore directly          │    │   │
│  │  └─────────────────────────────────────────────────┘    │   │
│  └─────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────┘
                                                  │
┌────────────────────────────────────────────────▼───────────────┐
│                          runc                                   │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ Reads org.criu.config annotation → passes to CRIU       │   │
│  └─────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────┘
                                                  │
┌────────────────────────────────────────────────▼───────────────┐
│                          CRIU                                   │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ cuda_plugin.so → cuda-checkpoint (NVIDIA)               │   │
│  │ Restores: process state, memory, GPU context            │   │
│  └─────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────┘
```

---

## Key Files Modified

### Patch File
A patch of all changes to `init_state.go` is saved at:
```
zzz/init_state_gpu_restore.patch
```

To apply in the future:
```bash
cd /path/to/grit
git apply zzz/init_state_gpu_restore.patch
```

### `cmd/containerd-shim-grit-v1/process/init_state.go`

The `Start()` method in `createdState` was modified to:

1. **Detect restore mode** via `grit.dev/restore-name` annotation
2. **Bypass nvidia-container-runtime** - calls `/usr/bin/runc restore` directly
3. **Parse CRIU mountpoints** using `crit decode -i mountpoints-XX.img`
4. **Create symlinks** for all kubelet-managed paths
5. **Handle containerd sandbox paths** (partially implemented)

**Key code sections:**
- Lines ~165-430: GPU restore logic
- Uses `crit` tool to decode CRIU images
- Creates symlinks at OLD paths pointing to NEW paths

---

## How to Reproduce This Setup

### Prerequisites

On the checkpoint/restore node (192.9.150.56):
```bash
# CRIU with CUDA plugin
apt install criu
ls /usr/lib/criu/cuda_plugin.so  # Should exist

# cuda-checkpoint tool
which cuda-checkpoint  # Should be in PATH

# crit tool (CRIU image tool)
which crit  # Should be in PATH

# Go 1.23+ for building shim
go version  # go1.23.4 or higher
```

### Building the Shim

```bash
# On the remote server
cd /tmp
mkdir -p grit-shim-update/cmd
# Copy source files from local machine

# Build
cd /tmp/grit-shim-update
go build -o containerd-shim-grit-v1 ./cmd/containerd-shim-grit-v1

# Deploy (requires stopping containerd)
sudo systemctl stop containerd
sudo pkill -9 -f containerd-shim
sudo cp containerd-shim-grit-v1 /usr/local/bin/
sudo systemctl start containerd
```

### Test Scripts Location

All test scripts are in `zzz/` directory:
- `full-restore-test-v2.sh` - Main end-to-end test
- `check-all-logs.sh` - Log analysis
- `check-sandbox.sh` - Sandbox path debugging
- `full-build-deploy.sh` - Build and deploy shim

### Running the Test

```bash
# On remote server
/tmp/full-restore-test-v2.sh
```

This will:
1. Deploy a GPU test pod
2. Wait for GPU memory allocation
3. Create checkpoint
4. Scale down deployment
5. Create restore CRD
6. Scale up to trigger restore
7. Check GPU memory after restore

---

## Debugging Commands

### Check containerd logs
```bash
sudo journalctl -u containerd --since "5 min ago" | grep -i "GPU restore"
```

### Check CRIU images
```bash
# List checkpoint files
ls -la /mnt/grit-agent/default/gpu-test-ckpt/cuda/checkpoint/

# Decode mountpoints
crit decode -i /mnt/grit-agent/default/gpu-test-ckpt/cuda/checkpoint/mountpoints-13.img --pretty

# Check for kubelet paths
crit decode -i .../mountpoints-13.img --pretty | grep kubelet

# Check for containerd sandbox paths
crit decode -i .../mountpoints-13.img --pretty | grep containerd
```

### Check symlinks created
```bash
ls -la /var/lib/kubelet/pods/*/volumes/kubernetes.io~projected/
ls -la /var/lib/kubelet/pods/*/etc-hosts
```

---

## Next Steps (Priority Order)

### 1. Fix Containerd Sandbox Symlinks (High Priority)
The sandbox ID detection exists but isn't working. Debug why `newSandboxID` is empty:

```go
// In init_state.go, add logging:
log.G(ctx).Infof("GPU restore: sandbox matches found: %d", len(sandboxMatches))
log.G(ctx).Infof("GPU restore: newSandboxID from annotation: %s", newSandboxID)
```

The annotation `io.kubernetes.cri.sandbox-id` should contain the new sandbox ID.

### 2. Investigate CUDA Plugin Stage 2 Failure (High Priority)
The logs show:
```
cuda_plugin: finished cuda_plugin stage 2 err -1
```

This indicates the CUDA restore is failing. Check:
- NVIDIA driver compatibility
- cuda-checkpoint version
- GPU device availability during restore

### 3. Verify Process Survives Restore (Medium Priority)
After restore, check if the process actually exists:
```bash
# Get PID from pidfile
cat /run/containerd/.../init.pid
ps aux | grep <PID>
```

### 4. Consider Alternative: Edit CRIU Images (Low Priority)
Instead of symlinks, use `crit` to directly edit mountpoint paths in the CRIU images before restore. This would be more robust but more complex.

---

## Environment Details

- **Kubernetes:** v1.28+
- **containerd:** v1.7+
- **CRIU:** 3.17+ with cuda_plugin.so
- **NVIDIA Driver:** 580.105.08
- **CUDA Version:** 13.0
- **GPU:** NVIDIA A10

---

## References

- [CRIU External Bind Mounts](https://criu.org/External_bind_mounts)
- [CRIU CUDA Plugin](https://github.com/checkpoint-restore/criu/tree/master/plugins/cuda)
- [runc checkpoint/restore](https://github.com/opencontainers/runc/blob/main/libcontainer/criu_linux.go)
- [Kubernetes Forensic Container Checkpointing](https://kubernetes.io/blog/2022/12/05/forensic-container-checkpointing-alpha/)
