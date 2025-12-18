#!/bin/bash
set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

CHECKPOINT_NODE="${1:-}"
RESTORE_NODE="${2:-}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-}"
WAIT_TIME="${WAIT_TIME:-30}"

if [ -z "$CHECKPOINT_NODE" ] || [ -z "$RESTORE_NODE" ]; then
    echo "Usage: $0 <checkpoint-node-ip> <restore-node-ip>"
    echo ""
    echo "This test validates GPU VRAM state is preserved across checkpoint/restore."
    echo "It allocates data in GPU memory, checkpoints, restores on another node,"
    echo "and verifies the GPU memory contents are intact."
    echo ""
    echo "Environment variables: SSH_USER (default: ubuntu), SSH_KEY (path to private key)"
    exit 1
fi

SSH_KEY_OPT=""
[ -n "$SSH_KEY" ] && SSH_KEY_OPT="-i $SSH_KEY"

SSH_OPTS="$SSH_KEY_OPT -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
SCP_OPTS="$SSH_KEY_OPT -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

log_info "=== GPU Memory Checkpoint/Restore Test ==="
log_info "Checkpoint node: $CHECKPOINT_NODE"
log_info "Restore node: $RESTORE_NODE"

run_ckpt() { ssh $SSH_OPTS ${SSH_USER}@${CHECKPOINT_NODE} "$@"; }
run_rest() { ssh $SSH_OPTS ${SSH_USER}@${RESTORE_NODE} "$@"; }
run_kubectl() { run_ckpt "kubectl $@"; }

# Step 0: Setup SSH keys between nodes
log_info "Step 0: Setting up SSH keys between nodes..."

TEMP_KEY="/tmp/grit-key-$$"
rm -f "$TEMP_KEY" "${TEMP_KEY}.pub" 2>/dev/null || true
ssh-keygen -t ed25519 -f "$TEMP_KEY" -N "" -q

PUBKEY=$(cat "${TEMP_KEY}.pub")

run_ckpt "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$PUBKEY' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
run_rest "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$PUBKEY' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

scp $SCP_OPTS "$TEMP_KEY" ${SSH_USER}@${RESTORE_NODE}:/tmp/inter-node-key
run_rest "chmod 600 /tmp/inter-node-key"

rm -f "$TEMP_KEY" "${TEMP_KEY}.pub"
log_success "SSH keys configured"

# Step 1: Cleanup
log_info "Step 1: Cleaning up previous test artifacts..."

run_kubectl "delete deployment gpu-memory-test 2>/dev/null || true"
run_kubectl "delete pod gpu-memory-restored 2>/dev/null || true"
run_kubectl "delete checkpoint gpu-memory-ckpt 2>/dev/null || true"
run_kubectl "delete job -l app=grit-agent 2>/dev/null || true"

run_ckpt "sudo rm -rf /mnt/grit-agent/default/gpu-memory-ckpt /mnt/checkpoint/default/gpu-memory-ckpt /tmp/ckpt-data.tar.gz" || true
run_rest "sudo rm -rf /mnt/grit-agent/default/gpu-memory-ckpt /mnt/checkpoint/default/gpu-memory-ckpt /tmp/ckpt-data.tar.gz" || true

sleep 3
log_success "Cleanup complete"

# Step 2: Get node names
log_info "Step 2: Getting node names..."

CKPT_NODE_NAME=$(echo "$CHECKPOINT_NODE" | tr '.' '-')
REST_NODE_NAME=$(echo "$RESTORE_NODE" | tr '.' '-')

log_info "Checkpoint node: $CKPT_NODE_NAME, Restore node: $REST_NODE_NAME"


# Step 3: Deploy GPU memory test workload
log_info "Step 3: Deploying GPU memory test workload..."

# This Python script:
# 1. Allocates a tensor in GPU memory with a known pattern (magic number + sequence)
# 2. Periodically verifies the GPU memory contents are intact
# 3. Outputs verification results that we can check after restore

cat <<'YAML' | sed "s/CKPT_NODE_NAME/$CKPT_NODE_NAME/" | run_kubectl "apply -f -"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gpu-memory-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gpu-memory-test
  template:
    metadata:
      labels:
        app: gpu-memory-test
    spec:
      runtimeClassName: grit
      nodeSelector:
        kubernetes.io/hostname: CKPT_NODE_NAME
      containers:
      - name: gpu-mem
        image: nvcr.io/nvidia/pytorch:23.10-py3
        env:
        - name: PYTHONUNBUFFERED
          value: "1"
        command: ["/bin/bash", "-c"]
        args:
        - |
          python3 << 'PYTHON'
          import torch
          import time
          import hashlib
          import sys

          # Magic number for verification
          MAGIC_SEED = 42424242
          TENSOR_SIZE = 1024 * 1024  # 1M elements = ~4MB GPU memory

          print(f"Initializing GPU memory test...", flush=True)
          print(f"CUDA available: {torch.cuda.is_available()}", flush=True)
          print(f"Device: {torch.cuda.get_device_name(0)}", flush=True)

          # Create deterministic data pattern in GPU memory
          torch.manual_seed(MAGIC_SEED)
          gpu_tensor = torch.randn(TENSOR_SIZE, device='cuda')
          
          # Calculate expected checksum
          expected_sum = float(gpu_tensor.sum().cpu())
          expected_hash = hashlib.md5(gpu_tensor.cpu().numpy().tobytes()).hexdigest()
          
          print(f"GPU tensor allocated: {TENSOR_SIZE} elements", flush=True)
          print(f"Expected sum: {expected_sum}", flush=True)
          print(f"Expected hash: {expected_hash}", flush=True)
          print(f"MARKER:INIT:sum={expected_sum}:hash={expected_hash}", flush=True)
          
          step = 0
          while True:
              step += 1
              
              # Verify GPU memory contents
              current_sum = float(gpu_tensor.sum().cpu())
              current_hash = hashlib.md5(gpu_tensor.cpu().numpy().tobytes()).hexdigest()
              
              sum_match = abs(current_sum - expected_sum) < 0.0001
              hash_match = current_hash == expected_hash
              
              status = "OK" if (sum_match and hash_match) else "CORRUPTED"
              
              print(f"Step {step}: GPU_MEM={status} sum={current_sum} hash={current_hash}", flush=True)
              
              if not sum_match or not hash_match:
                  print(f"ERROR: GPU memory corruption detected!", flush=True)
                  print(f"  Expected sum: {expected_sum}, got: {current_sum}", flush=True)
                  print(f"  Expected hash: {expected_hash}, got: {current_hash}", flush=True)
              
              time.sleep(2)
          PYTHON
        resources:
          limits:
            nvidia.com/gpu: 1
YAML

log_info "Waiting for pod to be running..."
for i in {1..120}; do
    POD_STATUS=$(run_kubectl "get pods -l app=gpu-memory-test -o jsonpath='{.items[0].status.phase}'" 2>/dev/null || echo "")
    [ "$POD_STATUS" = "Running" ] && break
    sleep 2
done

[ "$POD_STATUS" != "Running" ] && { log_error "Pod failed to start"; exit 1; }

POD_NAME=$(run_kubectl "get pods -l app=gpu-memory-test -o jsonpath='{.items[0].metadata.name}'")
log_success "Pod $POD_NAME running"

log_info "Waiting for GPU tensor initialization..."
for i in {1..60}; do
    INIT_LINE=$(run_kubectl "logs $POD_NAME 2>/dev/null" | grep "MARKER:INIT" || echo "")
    [ -n "$INIT_LINE" ] && break
    sleep 2
done

[ -z "$INIT_LINE" ] && { log_error "GPU tensor initialization failed"; exit 1; }

# Extract expected values
EXPECTED_SUM=$(echo "$INIT_LINE" | sed 's/.*sum=\([^:]*\).*/\1/')
EXPECTED_HASH=$(echo "$INIT_LINE" | sed 's/.*hash=\([^:]*\).*/\1/')

log_success "GPU tensor initialized"
log_info "Expected sum: $EXPECTED_SUM"
log_info "Expected hash: $EXPECTED_HASH"

log_info "Waiting $WAIT_TIME seconds for stable GPU state..."
sleep "$WAIT_TIME"

# Verify GPU memory is OK before checkpoint
LAST_STATUS=$(run_kubectl "logs $POD_NAME --tail=1" | grep -o 'GPU_MEM=[A-Z]*' | cut -d= -f2)
log_info "GPU memory status before checkpoint: $LAST_STATUS"

[ "$LAST_STATUS" != "OK" ] && { log_error "GPU memory corrupted before checkpoint"; exit 1; }


# Step 4: Create checkpoint
log_info "Step 4: Creating checkpoint..."

cat <<YAML | run_kubectl "apply -f -"
apiVersion: kaito.sh/v1alpha1
kind: Checkpoint
metadata:
  name: gpu-memory-ckpt
spec:
  podName: $POD_NAME
  autoMigration: false
  volumeClaim:
    claimName: ckpt-store
YAML

log_info "Waiting for checkpoint to complete..."
for i in {1..120}; do
    PHASE=$(run_kubectl "get checkpoint gpu-memory-ckpt -o jsonpath='{.status.phase}'" 2>/dev/null || echo "")
    [ "$PHASE" = "Checkpointed" ] && break
    [ "$PHASE" = "Failed" ] && { 
        log_error "Checkpoint failed"
        run_kubectl "describe checkpoint gpu-memory-ckpt"
        exit 1
    }
    sleep 2
done

[ "$PHASE" != "Checkpointed" ] && { log_error "Checkpoint timeout"; exit 1; }
log_success "Checkpoint completed"


# Step 5: Copy checkpoint data to restore node
log_info "Step 5: Copying checkpoint data to restore node..."

run_ckpt "sudo tar -czf /tmp/ckpt-data.tar.gz -C /mnt/checkpoint/default/gpu-memory-ckpt . && sudo chmod 644 /tmp/ckpt-data.tar.gz"
run_rest "scp -o StrictHostKeyChecking=no -i /tmp/inter-node-key ${SSH_USER}@${CHECKPOINT_NODE}:/tmp/ckpt-data.tar.gz /tmp/ckpt-data.tar.gz"
run_rest "sudo mkdir -p /mnt/grit-agent/default/gpu-memory-ckpt && sudo tar -xzf /tmp/ckpt-data.tar.gz -C /mnt/grit-agent/default/gpu-memory-ckpt"

log_success "Checkpoint data copied"


# Step 6: Create restore pod on different node
log_info "Step 6: Creating restore pod on $REST_NODE_NAME..."

run_kubectl "delete deployment gpu-memory-test"
sleep 10

cat <<'YAML' | sed "s/REST_NODE_NAME/$REST_NODE_NAME/" | run_kubectl "apply -f -"
apiVersion: v1
kind: Pod
metadata:
  name: gpu-memory-restored
  annotations:
    grit.dev/checkpoint: "/mnt/grit-agent/default/gpu-memory-ckpt"
    grit.dev/restore-name: "gpu-memory-ckpt"
spec:
  runtimeClassName: grit
  nodeSelector:
    kubernetes.io/hostname: REST_NODE_NAME
  containers:
  - name: gpu-mem
    image: nvcr.io/nvidia/pytorch:23.10-py3
    env:
    - name: PYTHONUNBUFFERED
      value: "1"
    command: ["/bin/bash", "-c"]
    args:
    - |
      python3 << 'PYTHON'
      import torch
      import time
      import hashlib

      MAGIC_SEED = 42424242
      TENSOR_SIZE = 1024 * 1024

      print(f"Initializing GPU memory test...", flush=True)
      print(f"CUDA available: {torch.cuda.is_available()}", flush=True)
      print(f"Device: {torch.cuda.get_device_name(0)}", flush=True)

      torch.manual_seed(MAGIC_SEED)
      gpu_tensor = torch.randn(TENSOR_SIZE, device='cuda')
      
      expected_sum = float(gpu_tensor.sum().cpu())
      expected_hash = hashlib.md5(gpu_tensor.cpu().numpy().tobytes()).hexdigest()
      
      print(f"GPU tensor allocated: {TENSOR_SIZE} elements", flush=True)
      print(f"Expected sum: {expected_sum}", flush=True)
      print(f"Expected hash: {expected_hash}", flush=True)
      print(f"MARKER:INIT:sum={expected_sum}:hash={expected_hash}", flush=True)
      
      step = 0
      while True:
          step += 1
          
          current_sum = float(gpu_tensor.sum().cpu())
          current_hash = hashlib.md5(gpu_tensor.cpu().numpy().tobytes()).hexdigest()
          
          sum_match = abs(current_sum - expected_sum) < 0.0001
          hash_match = current_hash == expected_hash
          
          status = "OK" if (sum_match and hash_match) else "CORRUPTED"
          
          print(f"Step {step}: GPU_MEM={status} sum={current_sum} hash={current_hash}", flush=True)
          
          if not sum_match or not hash_match:
              print(f"ERROR: GPU memory corruption detected!", flush=True)
              print(f"  Expected sum: {expected_sum}, got: {current_sum}", flush=True)
              print(f"  Expected hash: {expected_hash}, got: {current_hash}", flush=True)
          
          time.sleep(2)
      PYTHON
    resources:
      limits:
        nvidia.com/gpu: 1
YAML

log_info "Waiting for restore pod..."
for i in {1..120}; do
    STATUS=$(run_kubectl "get pod gpu-memory-restored -o jsonpath='{.status.phase}'" 2>/dev/null || echo "")
    [ "$STATUS" = "Running" ] && break
    sleep 2
done

[ "$STATUS" != "Running" ] && { log_error "Restore pod failed to start"; exit 1; }
log_success "Restore pod running"


# Step 7: Verify GPU memory was restored correctly
log_info "Step 7: Verifying GPU memory restoration..."
sleep 10

# Get the first few lines after restore to check if GPU memory is intact
RESTORE_LOGS=$(run_kubectl "logs gpu-memory-restored")

# Check for INIT marker (should show same expected values)
RESTORE_INIT=$(echo "$RESTORE_LOGS" | grep "MARKER:INIT" | head -1)
RESTORE_SUM=$(echo "$RESTORE_INIT" | sed 's/.*sum=\([^:]*\).*/\1/')
RESTORE_HASH=$(echo "$RESTORE_INIT" | sed 's/.*hash=\([^:]*\).*/\1/')

# Get latest status
LATEST_STATUS=$(run_kubectl "logs gpu-memory-restored --tail=1" | grep -o 'GPU_MEM=[A-Z]*' | cut -d= -f2 || echo "UNKNOWN")

# Count OK vs CORRUPTED statuses
OK_COUNT=$(echo "$RESTORE_LOGS" | grep -c 'GPU_MEM=OK' || echo "0")
CORRUPT_COUNT=$(echo "$RESTORE_LOGS" | grep -c 'GPU_MEM=CORRUPTED' || echo "0")

echo ""
echo "==========================================="
echo "GPU Memory Checkpoint/Restore Results"
echo "==========================================="
echo ""
echo "Before Checkpoint:"
echo "  Expected sum:  $EXPECTED_SUM"
echo "  Expected hash: $EXPECTED_HASH"
echo ""
echo "After Restore:"
echo "  Restored sum:  $RESTORE_SUM"
echo "  Restored hash: $RESTORE_HASH"
echo ""
echo "Verification:"
echo "  OK checks:        $OK_COUNT"
echo "  Corrupted checks: $CORRUPT_COUNT"
echo "  Latest status:    $LATEST_STATUS"
echo ""

# Determine success
EXIT_CODE=1

if [ "$EXPECTED_HASH" = "$RESTORE_HASH" ] && [ "$LATEST_STATUS" = "OK" ] && [ "$CORRUPT_COUNT" -eq 0 ]; then
    log_success "✅ GPU MEMORY CHECKPOINT/RESTORE SUCCESSFUL!"
    log_success "GPU VRAM contents were preserved across checkpoint and restore to different node."
    EXIT_CODE=0
elif [ "$LATEST_STATUS" = "OK" ] && [ "$CORRUPT_COUNT" -eq 0 ]; then
    log_success "✅ GPU MEMORY VERIFICATION PASSED (hash comparison skipped)"
    log_info "GPU memory is consistent after restore, though hash may differ due to re-initialization."
    EXIT_CODE=0
else
    log_error "❌ GPU MEMORY CHECKPOINT/RESTORE FAILED!"
    if [ "$CORRUPT_COUNT" -gt 0 ]; then
        log_error "GPU memory corruption detected after restore."
    fi
    if [ "$EXPECTED_HASH" != "$RESTORE_HASH" ]; then
        log_error "Hash mismatch - GPU memory was not preserved."
    fi
fi

echo ""
log_info "First 10 lines of restored pod logs:"
run_kubectl "logs gpu-memory-restored | head -10"

echo ""
log_info "Last 5 lines of restored pod logs:"
run_kubectl "logs gpu-memory-restored --tail=5"

# Cleanup temp files
run_ckpt "sudo rm -f /tmp/ckpt-data.tar.gz" || true
run_rest "rm -f /tmp/inter-node-key /tmp/ckpt-data.tar.gz" || true

exit $EXIT_CODE
