#!/bin/bash
set -eo pipefail

# ============================================================================
# GRIT Same-Node Restore Test
# Tests checkpoint/restore on the SAME node with the SAME GPU
# This validates checkpoint files are correct before cross-GPU migration
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

K3S_SERVER="${1:-}"      # k3s control-plane (for kubectl)
TARGET_NODE="${2:-}"     # Node to run pod on (with working GPU)
SSH_USER="${SSH_USER:-ubuntu}"
WAIT_TIME="${WAIT_TIME:-20}"

if [ -z "$K3S_SERVER" ]; then
    echo "Usage: $0 <k3s-server-ip> [target-node-ip]"
    echo "Example: SSH_USER=ubuntu $0 192.9.150.56 146.235.218.7"
    echo "If target-node-ip is omitted, uses k3s-server-ip"
    exit 1
fi

# Default target node to k3s server if not specified
TARGET_NODE="${TARGET_NODE:-$K3S_SERVER}"

SSH_KEY="${SSH_KEY:-~/.ssh/krish_key}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -i $SSH_KEY"

log_info "K3s server: $K3S_SERVER"
log_info "Target node for GPU workload: $TARGET_NODE"

run_ssh() { ssh $SSH_OPTS ${SSH_USER}@${K3S_SERVER} "$@"; }
run_target() { ssh $SSH_OPTS ${SSH_USER}@${TARGET_NODE} "$@"; }
run_kubectl() { run_ssh "kubectl $@"; }

# Get node name from TARGET_NODE IP (convert dots to dashes, k3s naming convention)
NODE_NAME=$(echo "$TARGET_NODE" | tr '.' '-')

# Verify node exists in cluster
NODE_EXISTS=$(run_kubectl "get node $NODE_NAME -o name" 2>/dev/null || echo "")
if [ -z "$NODE_EXISTS" ]; then
    log_error "Node $NODE_NAME not found in cluster. Available nodes:"
    run_kubectl "get nodes"
    exit 1
fi
log_info "Target node name: $NODE_NAME"

# Get GPU UUID from target node
GPU_UUID=$(run_target "nvidia-smi -L | grep -oP 'UUID: \K[^)]+'" | head -1)
log_info "GPU UUID: $GPU_UUID"

# Step 1: Cleanup
log_info "Step 1: Cleaning up previous test artifacts..."

run_kubectl "delete deployment gpu-counter 2>/dev/null || true"
run_kubectl "delete pod gpu-counter-restored 2>/dev/null || true"
run_kubectl "delete checkpoint gpu-counter-ckpt 2>/dev/null || true"
run_kubectl "delete job -l grit.dev/helper=grit-agent 2>/dev/null || true"

# Wait for pods to terminate
log_info "Waiting for pods to terminate..."
for i in {1..30}; do
    PODS=$(run_kubectl "get pods -l app=gpu-counter --no-headers 2>/dev/null" || echo "")
    RESTORE_POD=$(run_kubectl "get pod gpu-counter-restored --no-headers 2>/dev/null" || echo "")
    [ -z "$PODS" ] && [ -z "$RESTORE_POD" ] && break
    sleep 2
done

run_target "sudo rm -rf /mnt/grit-agent/default/ /mnt/checkpoint/default/ /mnt/pvc-data/default/" || true
sleep 3
log_success "Cleanup complete"


# Step 2: Deploy GPU counter
log_info "Step 2: Deploying GPU counter application..."

cat <<YAML | run_kubectl "apply -f -"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gpu-counter
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gpu-counter
  template:
    metadata:
      labels:
        app: gpu-counter
    spec:
      runtimeClassName: grit
      nodeSelector:
        kubernetes.io/hostname: $NODE_NAME
      containers:
      - name: counter
        image: nvcr.io/nvidia/pytorch:24.01-py3
        command: ["python3", "-c"]
        args:
        - |
          import torch
          import time
          print("Initializing CUDA...")
          device = torch.device("cuda:0")
          print(f"Using device: {device}")
          # Allocate GPU tensor to create CUDA context
          x = torch.randn(1000, 1000, device=device)
          print(f"GPU tensor allocated: {x.shape}")
          step = 0
          while True:
              step += 10
              # Do some GPU work to keep context active
              y = torch.matmul(x, x)
              print(f"Step: {step}")
              time.sleep(1)
        resources:
          limits:
            nvidia.com/gpu: 1
YAML

log_info "Waiting for pod to start..."
for i in {1..60}; do
    POD_STATUS=$(run_kubectl "get pods -l app=gpu-counter -o jsonpath='{.items[0].status.phase}'" 2>/dev/null || echo "")
    [ "$POD_STATUS" = "Running" ] && break
    sleep 2
done

[ "$POD_STATUS" != "Running" ] && { log_error "Pod failed to start"; run_kubectl "describe pods -l app=gpu-counter"; exit 1; }

sleep 3
POD_NAME=$(run_kubectl "get pods -l app=gpu-counter -o jsonpath='{.items[0].metadata.name}'")
log_success "Pod $POD_NAME is running"

log_info "Letting counter run for $WAIT_TIME seconds..."
sleep "$WAIT_TIME"

CKPT_VALUE=$(run_kubectl "logs $POD_NAME --tail=1" | grep -o 'Step: [0-9]*' | cut -d' ' -f2)
log_info "Counter value before checkpoint: $CKPT_VALUE"


# Step 3: Create checkpoint
log_info "Step 3: Creating checkpoint..."

cat <<YAML | run_kubectl "apply -f -"
apiVersion: kaito.sh/v1alpha1
kind: Checkpoint
metadata:
  name: gpu-counter-ckpt
spec:
  podName: $POD_NAME
  autoMigration: false
  volumeClaim:
    claimName: ckpt-store
YAML

log_info "Waiting for checkpoint to complete..."
for i in {1..90}; do
    PHASE=$(run_kubectl "get checkpoint gpu-counter-ckpt -o jsonpath='{.status.phase}'" 2>/dev/null || echo "")
    log_info "  Checkpoint phase: $PHASE"
    [ "$PHASE" = "Checkpointed" ] && break
    [ "$PHASE" = "Failed" ] && { 
        log_error "Checkpoint failed"
        run_kubectl "describe checkpoint gpu-counter-ckpt"
        exit 1
    }
    sleep 3
done

[ "$PHASE" != "Checkpointed" ] && { log_error "Checkpoint timeout"; exit 1; }
log_success "Checkpoint completed successfully"

# Check checkpoint files
log_info "Verifying checkpoint files..."
run_target "sudo ls -la /mnt/checkpoint/default/gpu-counter-ckpt/ 2>/dev/null || echo 'Checkpoint directory not found'"


# Step 4: Copy checkpoint to restore location (same node)
log_info "Step 4: Copying checkpoint data to restore location..."

run_target "sudo mkdir -p /mnt/grit-agent/default/gpu-counter-ckpt"
run_target "sudo cp -r /mnt/checkpoint/default/gpu-counter-ckpt/* /mnt/grit-agent/default/gpu-counter-ckpt/"
run_target "sudo ls -la /mnt/grit-agent/default/gpu-counter-ckpt/"

log_success "Checkpoint data copied"


# Step 5: Delete original deployment
log_info "Step 5: Deleting original deployment..."

run_kubectl "delete deployment gpu-counter"

# Wait for original pod to terminate
log_info "Waiting for original pod to terminate..."
for i in {1..30}; do
    PODS=$(run_kubectl "get pods -l app=gpu-counter --no-headers 2>/dev/null" || echo "")
    [ -z "$PODS" ] && break
    sleep 2
done

sleep 5
log_success "Original deployment deleted"


# Step 6: Create restore pod (SAME node, SAME GPU)
log_info "Step 6: Creating restore pod on SAME node..."

cat <<YAML | run_kubectl "apply -f -"
apiVersion: v1
kind: Pod
metadata:
  name: gpu-counter-restored
  annotations:
    grit.dev/checkpoint: "/mnt/grit-agent/default/gpu-counter-ckpt"
    grit.dev/restore-name: "gpu-counter-ckpt"
spec:
  runtimeClassName: grit
  nodeSelector:
    kubernetes.io/hostname: $NODE_NAME
  containers:
  - name: counter
    image: nvcr.io/nvidia/pytorch:24.01-py3
    command: ["python3", "-c"]
    args:
    - |
      import torch
      import time
      print("Initializing CUDA...")
      device = torch.device("cuda:0")
      print(f"Using device: {device}")
      x = torch.randn(1000, 1000, device=device)
      print(f"GPU tensor allocated: {x.shape}")
      step = 0
      while True:
          step += 10
          y = torch.matmul(x, x)
          print(f"Step: {step}")
          time.sleep(1)
    resources:
      limits:
        nvidia.com/gpu: 1
YAML

log_info "Waiting for restore pod..."
for i in {1..60}; do
    STATUS=$(run_kubectl "get pod gpu-counter-restored -o jsonpath='{.status.phase}'" 2>/dev/null || echo "")
    CONTAINER_STATUS=$(run_kubectl "get pod gpu-counter-restored -o jsonpath='{.status.containerStatuses[0].state}'" 2>/dev/null || echo "")
    log_info "  Pod status: $STATUS, Container: $CONTAINER_STATUS"
    [ "$STATUS" = "Running" ] && break
    [ "$STATUS" = "Failed" ] && { 
        log_error "Restore pod failed"
        run_kubectl "describe pod gpu-counter-restored"
        run_kubectl "logs gpu-counter-restored" || true
        exit 1
    }
    sleep 3
done

if [ "$STATUS" != "Running" ]; then
    log_error "Restore pod not running"
    run_kubectl "describe pod gpu-counter-restored"
    run_kubectl "logs gpu-counter-restored" || true
    exit 1
fi

log_success "Restore pod is running"


# Step 7: Verify restore
log_info "Step 7: Verifying restore..."
sleep 5

FIRST_LINE=$(run_kubectl "logs gpu-counter-restored | head -5")
echo "First 5 lines of restored pod:"
echo "$FIRST_LINE"

REST_START=$(echo "$FIRST_LINE" | grep -o 'Step: [0-9]*' | head -1 | cut -d' ' -f2 || echo "0")
CURRENT=$(run_kubectl "logs gpu-counter-restored --tail=1" | grep -o 'Step: [0-9]*' | cut -d' ' -f2)

echo ""
echo "==========================================="
echo "RESULTS"
echo "==========================================="
echo "GPU UUID:              $GPU_UUID"
echo "Checkpoint value:      $CKPT_VALUE"
echo "Restore start value:   $REST_START"
echo "Current value:         $CURRENT"
echo ""

# Success if restore started from near checkpoint value (allowing some tolerance)
if [ -n "$REST_START" ] && [ "$REST_START" -gt 0 ] && [ "$REST_START" -ge "$((CKPT_VALUE - 200))" ]; then
    log_success "✅ SAME-NODE RESTORE SUCCESSFUL!"
    log_success "Counter resumed from checkpoint value!"
    EXIT_CODE=0
else
    log_error "❌ RESTORE FAILED"
    log_error "Counter started from $REST_START instead of ~$CKPT_VALUE"
    log_info "This means checkpoint files may not be valid or GRIT restore isn't working"
    EXIT_CODE=1
fi

echo ""
echo "Full pod logs (last 10 lines):"
run_kubectl "logs gpu-counter-restored --tail=10"

exit $EXIT_CODE

