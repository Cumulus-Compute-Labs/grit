# Recent Updates - GPU Checkpoint/Restore Setup

## Date: December 16, 2025

## Summary

Fixed critical GPU passthrough issue in the GRIT runtime configuration that was preventing containers from accessing NVIDIA GPUs.

## Current Status

✅ GPU passthrough working - containers can access GPUs via grit runtime
✅ Checkpoint creation works - CRIU successfully checkpoints GPU containers
❌ Cross-node restore fails - mount namespace mismatch between nodes
❌ PyTorch containers fail checkpoint - inotify file handles can't be dumped

## Problem

Containers using `runtimeClassName: grit` could not access GPUs. The error was:
```
RuntimeError: Found no NVIDIA driver on your system
```

Despite:
- NVIDIA driver being installed and working on the host
- NVIDIA device plugin running and detecting GPUs
- GPU showing in node capacity

## Root Cause

The GRIT runtime's `grit.toml` configuration was using plain `runc` instead of `nvidia-container-runtime`:

```toml
# WRONG - no GPU passthrough
BinaryName = "/usr/bin/runc"
```

The GRIT shim wraps whatever runtime is specified in `BinaryName`. When using plain `runc`, the NVIDIA container hooks that inject GPU devices into containers never run.

## Solution

Updated `/etc/containerd/grit.toml` on both nodes to use `nvidia-container-runtime`:

```toml
# CORRECT - enables GPU passthrough
BinaryName = "/usr/bin/nvidia-container-runtime"
Root = "/run/containerd/runc"
SystemdCgroup = false
```

Then restarted containerd:
```bash
sudo systemctl restart containerd
```

## Files Updated

1. **scripts/setup-containerd-grit.sh** - Already had correct config (uses nvidia-container-runtime)
2. **working/setup-checkpoint-node.sh** - Updated to use nvidia-container-runtime
3. **working/setup-restore-node.sh** - Updated to use nvidia-container-runtime  
4. **working/test-gpu-memory-checkpoint.sh** - New test script for GPU VRAM checkpoint validation

## New Test Script

Created `working/test-gpu-memory-checkpoint.sh` which:
- Allocates a PyTorch tensor in GPU VRAM with a deterministic pattern
- Computes MD5 hash of GPU memory contents
- Checkpoints the container
- Restores on a different node
- Verifies GPU memory contents match (hash comparison)

This tests actual GPU memory state preservation, not just CPU process state.

## Commands Used to Fix

```bash
# On checkpoint node (150.136.214.243)
ssh ubuntu@150.136.214.243 "sudo sed -i 's|BinaryName = \"/usr/bin/runc\"|BinaryName = \"/usr/bin/nvidia-container-runtime\"|' /etc/containerd/grit.toml"
ssh ubuntu@150.136.214.243 "sudo systemctl restart containerd"

# On restore node (150.136.142.227)
ssh ubuntu@150.136.142.227 "sudo sed -i 's|BinaryName = \"/usr/bin/runc\"|BinaryName = \"/usr/bin/nvidia-container-runtime\"|' /etc/containerd/grit.toml"
ssh ubuntu@150.136.142.227 "sudo systemctl restart containerd"
```

## Verification

After the fix, containers with `runtimeClassName: grit` can access GPUs:
```bash
kubectl exec <pod> -- nvidia-smi
# Shows GPU info successfully
```

## Test Nodes

- Checkpoint Node: 150.136.214.243 (k3s server, control-plane)
- Restore Node: 150.136.142.227 (k3s agent)

## Additional Notes

- The original test script `test-checkpoint-restore.sh` runs kubectl via the restore node, but kubectl is only configured on the control-plane node. Fixed by changing `run_kubectl()` to use `run_ckpt` instead of `run_rest`.
- Python stdout buffering was causing logs to not appear. Fixed by adding `PYTHONUNBUFFERED=1` env var and `flush=True` to print statements.


## Cross-Node Restore Issue

When attempting to restore a checkpoint on a different node, CRIU fails with:
```
Error (criu/mount.c:3141): mnt: No mapping for 1373:(null) mountpoint
```

This is because:
1. Mount IDs are node-specific (different on each machine)
2. CRIU checkpoint captures mount IDs from the source node
3. On restore, CRIU can't find matching mount IDs on the target node

This is a known limitation of CRIU for cross-node migration. Possible solutions:
- Use identical mount configurations on both nodes
- Use CRIU's `--ext-mount-map` option to remap mounts
- Ensure both nodes have identical container runtime configurations

## PyTorch Container Checkpoint Issue

PyTorch containers fail to checkpoint with:
```
Error (criu/fsnotify.c:284): fsnotify: Can't dump that handle
```

This is because PyTorch (or its dependencies) uses inotify file watchers that CRIU cannot checkpoint. The simpler CUDA base image (`nvcr.io/nvidia/cuda:12.2.0-base-ubuntu22.04`) works for checkpoint but still has the cross-node restore issue.

## Test Results

| Test | Checkpoint | Same-Node Restore | Cross-Node Restore |
|------|------------|-------------------|-------------------|
| CUDA base (bash counter) | ✅ | Not tested | ❌ Mount mismatch |
| PyTorch (GPU memory test) | ❌ inotify | N/A | N/A |
