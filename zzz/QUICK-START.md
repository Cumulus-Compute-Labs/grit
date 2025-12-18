# Quick Start - GPU Checkpoint/Restore Testing

## SSH to Test Node
```bash
wsl -e bash -c "ssh -i ~/.ssh/krish_key ubuntu@192.9.150.56"
```

## Build & Deploy Shim (from Windows)
```powershell
# One-liner to build and deploy
wsl -e bash -c "ssh -i ~/.ssh/krish_key ubuntu@192.9.150.56 'rm -rf /tmp/grit-shim-update; mkdir -p /tmp/grit-shim-update/cmd' && cd /mnt/c/Users/krish/Documents/GitHub/grit && scp -i ~/.ssh/krish_key -r cmd/containerd-shim-grit-v1 ubuntu@192.9.150.56:/tmp/grit-shim-update/cmd/ && scp -i ~/.ssh/krish_key -r pkg ubuntu@192.9.150.56:/tmp/grit-shim-update/ && scp -i ~/.ssh/krish_key go.mod go.sum ubuntu@192.9.150.56:/tmp/grit-shim-update/ && ssh -i ~/.ssh/krish_key ubuntu@192.9.150.56 '/tmp/full-build-deploy.sh 2>&1'"
```

## Run Full Test
```bash
# On remote server
/tmp/full-restore-test-v2.sh
```

## Check Logs
```bash
# GPU restore logs
sudo journalctl -u containerd --since "5 min ago" | grep -i "GPU restore"

# Symlink creation
sudo journalctl -u containerd --since "5 min ago" | grep -i symlink

# Restore errors  
sudo journalctl -u containerd --since "5 min ago" | grep -i "runc restore failed"
```

## Cleanup Between Tests
```bash
kubectl delete checkpoint gpu-test-ckpt --ignore-not-found
kubectl delete restore gpu-test-restore --ignore-not-found
kubectl delete pods --all --force --grace-period=0
```

## Key Files on Remote Server

| File | Purpose |
|------|---------|
| `/usr/local/bin/containerd-shim-grit-v1` | The custom shim binary |
| `/tmp/full-build-deploy.sh` | Script to build and deploy shim |
| `/tmp/full-restore-test-v2.sh` | Main test script |
| `/tmp/check-all-logs.sh` | Log analysis script |
| `/mnt/grit-agent/default/gpu-test-ckpt/cuda/checkpoint/` | Checkpoint data |

## Key Files Locally

| File | Purpose |
|------|---------|
| `cmd/containerd-shim-grit-v1/process/init_state.go` | Main restore logic |
| `zzz/GPU-CHECKPOINT-RESTORE-STATUS.md` | Full status doc |

## Current Blocker

**Containerd sandbox paths** for `/etc/hostname` are not being symlinked. The error:
```
Can't bind-mount at .../etc/hostname: No such file or directory
```

Fix: Debug why `newSandboxID` is empty in the sandbox symlink code.
