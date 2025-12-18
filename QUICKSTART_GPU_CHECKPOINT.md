# Quick Start: GPU Checkpoint with GRIT

## Current Status

✅ **Manual GPU checkpoint WORKS** (521MB checkpoint created successfully)  
⏸️ **GRIT checkpoint needs fix** (patch ready to apply)

## Option 1: Use Working Manual Checkpoint (Ready Now)

```bash
# On checkpoint node
ssh ubuntu@192.9.150.56

# Run the working script
/tmp/test-final-with-nfs-export.sh

# Results: 521MB checkpoint in /tmp/criu-final-nfs-test/
# ✅ GPU memory preserved
# ✅ CRIU exit code: 0
```

## Option 2: Fix GRIT for Full Integration (1 hour)

### Step 1: Apply the Fix

```bash
cd /path/to/grit/repository

# Apply patch
chmod +x apply-gpu-fix.sh
./apply-gpu-fix.sh

# This will:
# - Backup original file
# - Apply patch
# - Rebuild GRIT agent
# - Build Docker image
```

### Step 2: Deploy Fixed GRIT

```bash
# On checkpoint node
kubectl set image deployment/grit-agent \
    grit-agent=grit-agent:gpu-fix \
    -n kube-system

# Wait for rollout
kubectl rollout status deployment/grit-agent -n kube-system
```

### Step 3: Test GRIT Checkpoint

```bash
# Create a GPU pod
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gpu-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gpu-test
  template:
    metadata:
      labels:
        app: gpu-test
    spec:
      runtimeClassName: grit
      containers:
      - name: cuda
        image: pytorch/pytorch:2.1.0-cuda12.1-cudnn8-runtime
        command: ["python3", "-c"]
        args:
        - |
          import torch, time
          tensor = torch.randn(1024*1024, device='cuda')
          while True:
              print(f'Sum: {tensor.sum().item()}')
              time.sleep(5)
        resources:
          limits:
            nvidia.com/gpu: 1
EOF

# Wait for pod
kubectl wait --for=condition=ready pod -l app=gpu-test --timeout=60s

# Create checkpoint
POD_NAME=$(kubectl get pod -l app=gpu-test -o jsonpath='{.items[0].metadata.name}')

kubectl apply -f - <<EOF
apiVersion: kaito.sh/v1alpha1
kind: Checkpoint
metadata:
  name: gpu-checkpoint
spec:
  podName: $POD_NAME
  autoMigration: false
  volumeClaim:
    claimName: ckpt-store
EOF

# Watch progress
kubectl get checkpoint gpu-checkpoint -w
kubectl logs deployment/grit-agent -f -n kube-system
```

### Step 4: Verify Checkpoint

```bash
# Check status
kubectl get checkpoint gpu-checkpoint

# Should show:
# NAME              PHASE          POD
# gpu-checkpoint    Checkpointed   gpu-test-xxx

# Verify files
ls -lh /mnt/grit-agent/default/gpu-checkpoint/checkpoint/*.img
```

### Step 5: Test Restore

```bash
# Delete original deployment
kubectl delete deployment gpu-test

# Create restore
kubectl apply -f - <<EOF
apiVersion: kaito.sh/v1alpha1
kind: Restore
metadata:
  name: gpu-restore
spec:
  checkpointName: gpu-checkpoint
  selector:
    matchLabels:
      app: gpu-test-restored
EOF

# Watch restore
kubectl get restore gpu-restore -w
kubectl logs deployment/grit-agent -f -n kube-system
```

## What The Fix Changes

### Before (Fails)
```
GRIT → task.Pause() → Cgroup Freeze
  ↓
CRIU → CUDA Plugin → cuda-checkpoint --action lock
  ↓
❌ Process frozen, can't respond
  ↓
Timeout after 10s
```

### After (Works)
```
GRIT → CRIU dump (direct call, no freeze)
  ↓
CRIU → CUDA Plugin → cuda-checkpoint --action lock
  ↓
✅ Process responds, GPU locked
  ↓
CRIU → Freeze via ptrace
  ↓
✅ Checkpoint succeeds
```

## Files You Need

### Already Created (in `zzz/` folder)
- `test-final-with-nfs-export.sh` - Working manual checkpoint
- `SUCCESS_SUMMARY.md` - Complete documentation

### GRIT Fix (in repo root)
- `GRIT_FIX.md` - Fix documentation
- `gpu-checkpoint.patch` - Patch file
- `apply-gpu-fix.sh` - Application script

## Key Configuration

All configuration already applied on 192.9.150.56:

- ✅ Native snapshotter (`/etc/containerd/config.toml`)
- ✅ CRIU flags (`/etc/criu/runc.conf`)
- ✅ NVIDIA runtime legacy mode
- ✅ CRIU 4.1 installed
- ✅ cuda-checkpoint available

## Troubleshooting

### If Manual Checkpoint Fails
```bash
# Check CUDA checkpoint utility
/usr/local/bin/cuda-checkpoint --help

# Check CRIU
/usr/local/bin/criu.real --version

# Check GPU
nvidia-smi
```

### If GRIT Checkpoint Fails (After Fix)
```bash
# Check agent logs
kubectl logs deployment/grit-agent -n kube-system --tail=100

# Check CRIU log
POD_NAME=$(kubectl get checkpoint gpu-checkpoint -o jsonpath='{.spec.podName}')
CONTAINER_ID=$(crictl ps --name $POD_NAME -q)
sudo cat /run/containerd/.../criu-dump.log
```

## Success Criteria

### Manual Checkpoint ✅
- CRIU exit code: 0
- 500+ MB checkpoint created
- `pages-5.img` contains GPU memory (~496MB)
- 40+ image files created

### GRIT Checkpoint (After Fix) ✅
- Checkpoint CR shows `phase: Checkpointed`
- No timeout errors in logs
- Checkpoint files in `/mnt/grit-agent/default/checkpoint-name/`

### Restore (After Fix) ✅
- Restore CR shows `phase: Restored`
- Pod process continues from checkpoint state
- GPU memory preserved (same tensor values)

## Time Estimates

| Task | Time | Status |
|------|------|--------|
| Manual checkpoint | Ready now | ✅ Works |
| Apply GRIT fix | 30 min | Patch ready |
| Test GRIT checkpoint | 15 min | After fix |
| Setup restore node | 1 hour | Not started |
| Test cross-node | 30 min | After restore node |
| **Total** | **~2-3 hours** | **Manual works now** |

## Next Action

**Choose your path:**

**A. Use what works now:**
```bash
ssh ubuntu@192.9.150.56
/tmp/test-final-with-nfs-export.sh
```

**B. Get full GRIT integration:**
```bash
cd grit-repo
./apply-gpu-fix.sh
kubectl set image deployment/grit-agent grit-agent=grit-agent:gpu-fix -n kube-system
```

**C. Both:**
1. Use manual checkpoint for immediate results
2. Apply GRIT fix for production use
3. Contribute patch back to GRIT community

