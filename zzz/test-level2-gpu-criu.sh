#!/bin/bash
set -eo pipefail

# =============================================================================
# Level 2: GPU CRIU Test
# Tests if GRIT checkpoint/restore works with GPU containers
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

NODE_IP="${1:-192.9.150.56}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-~/.ssh/krish_key}"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -i $SSH_KEY"

log_info "=== Level 2: GPU CRIU Test ==="
log_info "K3s Server: $NODE_IP"

run_ssh() { ssh $SSH_OPTS ${SSH_USER}@${NODE_IP} "$@"; }
run_kubectl() { run_ssh "kubectl $@"; }

# Pin to the k3s server node
NODE_NAME=$(echo "$NODE_IP" | tr '.' '-')
log_info "Target node: $NODE_NAME"

# Cleanup
log_info "Cleaning up..."
run_kubectl "delete deployment gpu-counter 2>/dev/null || true"
run_kubectl "delete pod gpu-restored 2>/dev/null || true"
run_kubectl "delete checkpoint gpu-ckpt 2>/dev/null || true"
run_kubectl "delete job -l grit.dev/helper=grit-agent 2>/dev/null || true"
run_ssh "sudo rm -rf /mnt/grit-agent/default/ /mnt/checkpoint/default/" || true
sleep 5

# Deploy GPU counter
log_info "Deploying GPU counter..."
cat << EOF | run_kubectl "apply -f -"
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
        image: nvidia/cuda:12.2.0-base-ubuntu22.04
        securityContext:
          seccompProfile:
            type: Unconfined
          capabilities:
            add: ["SYS_ADMIN"]
        command: ["/bin/bash", "-c"]
        args:
        - |
          i=0
          while true; do
            i=\$((i + 10))
            # Touch GPU to create CUDA context
            nvidia-smi --query-gpu=memory.used --format=csv,noheader > /dev/null 2>&1
            echo "GPU-Step: \$i"
            sleep 1
          done
        resources:
          limits:
            nvidia.com/gpu: 1
EOF

log_info "Waiting for pod..."
for i in {1..120}; do
    STATUS=$(run_kubectl "get pods -l app=gpu-counter -o jsonpath='{.items[0].status.phase}'" 2>/dev/null || echo "")
    [ "$STATUS" = "Running" ] && break
    sleep 3
done

if [ "$STATUS" != "Running" ]; then
    log_error "Pod failed to start"
    run_kubectl "describe pods -l app=gpu-counter"
    exit 1
fi
sleep 5

POD_NAME=$(run_kubectl "get pods -l app=gpu-counter -o jsonpath='{.items[0].metadata.name}'")
log_success "Pod $POD_NAME running"

log_info "Letting GPU counter run for 20 seconds..."
sleep 20

CKPT_VALUE=$(run_kubectl "logs $POD_NAME --tail=1" | grep -o 'GPU-Step: [0-9]*' | cut -d' ' -f2 || echo "0")
log_info "Counter at checkpoint: $CKPT_VALUE"

if [ "$CKPT_VALUE" -lt 50 ]; then
    log_error "Counter didn't start properly"
    run_kubectl "logs $POD_NAME --tail=20"
    exit 1
fi

# Get container ID and PID for the unmount hack
log_info "Getting container info for unmount hack..."
CONTAINER_ID=$(run_ssh "sudo crictl ps --name counter -q | head -1")
log_info "Container ID: $CONTAINER_ID"

# Get the HOST PID (second "pid" field, not the one inside container which is 1)
CONTAINER_PID=$(run_ssh "sudo crictl inspect $CONTAINER_ID 2>/dev/null | grep '\"pid\":' | grep -v ': 1,' | head -1 | grep -o '[0-9]*'")
log_info "Container PID: $CONTAINER_PID"

# THE UNMOUNT HACK: Remove problematic NVIDIA proc mount before checkpoint
# The mount includes specific GPU ID like /proc/driver/nvidia/gpus/0000:06:00.0
log_info "Unmounting all /proc/driver/nvidia/gpus/* mounts inside container namespace..."
run_ssh "for mnt in \$(sudo cat /proc/$CONTAINER_PID/mountinfo | grep '/proc/driver/nvidia/gpus/' | awk '{print \$5}'); do echo \"Unmounting \$mnt\"; sudo nsenter -t $CONTAINER_PID -m umount -l \$mnt 2>/dev/null || true; done"

# Create checkpoint
log_info "Creating checkpoint..."
cat << EOF | run_kubectl "apply -f -"
apiVersion: kaito.sh/v1alpha1
kind: Checkpoint
metadata:
  name: gpu-ckpt
spec:
  podName: $POD_NAME
  autoMigration: false
  volumeClaim:
    claimName: ckpt-store
EOF

log_info "Waiting for checkpoint (this may take a while for GPU)..."
FAILED=false
for i in {1..120}; do
    PHASE=$(run_kubectl "get checkpoint gpu-ckpt -o jsonpath='{.status.phase}'" 2>/dev/null || echo "")
    echo "  Phase: $PHASE"
    [ "$PHASE" = "Checkpointed" ] && break
    if [ "$PHASE" = "Failed" ]; then
        FAILED=true
        break
    fi
    sleep 3
done

if [ "$FAILED" = "true" ] || [ "$PHASE" != "Checkpointed" ]; then
    log_error "Checkpoint failed!"
    run_kubectl "describe checkpoint gpu-ckpt"
    echo ""
    log_warn "Checking grit-agent logs..."
    run_kubectl "logs job/grit-agent-gpu-ckpt" 2>/dev/null || true
    echo ""
    log_warn "Checking CRIU dump log..."
    run_ssh "sudo cat /mnt/checkpoint/default/gpu-ckpt/counter/dump.log 2>/dev/null | tail -50" || true
    exit 1
fi

log_success "Checkpoint completed!"

# Copy checkpoint to restore location
log_info "Copying checkpoint data..."
run_ssh "sudo mkdir -p /mnt/grit-agent/default/gpu-ckpt"
run_ssh "sudo cp -r /mnt/checkpoint/default/gpu-ckpt/* /mnt/grit-agent/default/gpu-ckpt/"

# Delete original
log_info "Deleting original deployment..."
run_kubectl "delete deployment gpu-counter"
sleep 10

# Create restore pod
log_info "Creating restore pod..."
cat << EOF | run_kubectl "apply -f -"
apiVersion: v1
kind: Pod
metadata:
  name: gpu-restored
  annotations:
    grit.dev/checkpoint: "/mnt/grit-agent/default/gpu-ckpt"
    grit.dev/restore-name: "gpu-ckpt"
spec:
  runtimeClassName: grit
  nodeSelector:
    kubernetes.io/hostname: $NODE_NAME
  containers:
  - name: counter
    image: nvidia/cuda:12.2.0-base-ubuntu22.04
    securityContext:
      seccompProfile:
        type: Unconfined
      capabilities:
        add: ["SYS_ADMIN"]
    command: ["/bin/bash", "-c"]
    args:
    - |
      i=0
      while true; do
        i=\$((i + 10))
        nvidia-smi --query-gpu=memory.used --format=csv,noheader > /dev/null 2>&1
        echo "GPU-Step: \$i"
        sleep 1
      done
    resources:
      limits:
        nvidia.com/gpu: 1
EOF

log_info "Waiting for restore pod..."
for i in {1..90}; do
    STATUS=$(run_kubectl "get pod gpu-restored -o jsonpath='{.status.phase}'" 2>/dev/null || echo "")
    [ "$STATUS" = "Running" ] && break
    if [ "$STATUS" = "Failed" ]; then
        log_error "Restore pod failed"
        run_kubectl "describe pod gpu-restored"
        exit 1
    fi
    sleep 3
done

if [ "$STATUS" != "Running" ]; then
    log_error "Restore pod timeout"
    run_kubectl "describe pod gpu-restored"
    exit 1
fi
log_success "Restore pod running"

# Verify
log_info "Verifying restore..."
sleep 5

FIRST_LOG=$(run_kubectl "logs gpu-restored | head -5")
echo "$FIRST_LOG"

REST_START=$(echo "$FIRST_LOG" | grep -o 'GPU-Step: [0-9]*' | head -1 | cut -d' ' -f2 || echo "0")
CURRENT=$(run_kubectl "logs gpu-restored --tail=1" | grep -o 'GPU-Step: [0-9]*' | cut -d' ' -f2 || echo "0")

echo ""
echo "==========================================="
echo "RESULTS"
echo "==========================================="
echo "Checkpoint value:    $CKPT_VALUE"
echo "Restore start:       $REST_START"  
echo "Current value:       $CURRENT"
echo ""

if [ -n "$REST_START" ] && [ "$REST_START" -gt 50 ] && [ "$REST_START" -ge "$((CKPT_VALUE - 100))" ]; then
    log_success "✅ LEVEL 2 PASSED - GPU CRIU works!"
    log_info "GPU counter resumed from ~$REST_START (checkpoint was at $CKPT_VALUE)"
    exit 0
else
    log_error "❌ LEVEL 2 FAILED"
    log_error "Counter started from $REST_START instead of ~$CKPT_VALUE"
    exit 1
fi

