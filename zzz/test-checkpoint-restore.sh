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
WAIT_TIME="${WAIT_TIME:-20}"

if [ -z "$CHECKPOINT_NODE" ] || [ -z "$RESTORE_NODE" ]; then
    echo "Usage: $0 <checkpoint-node-ip> <restore-node-ip>"
    exit 1
fi

SSH_KEY="${SSH_KEY:-~/.ssh/krish_key}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -i $SSH_KEY"
SCP_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -i $SSH_KEY"

log_info "Checkpoint node: $CHECKPOINT_NODE"
log_info "Restore node: $RESTORE_NODE"

run_ckpt() { ssh $SSH_OPTS ${SSH_USER}@${CHECKPOINT_NODE} "$@"; }
run_rest() { ssh $SSH_OPTS ${SSH_USER}@${RESTORE_NODE} "$@"; }
# kubectl runs on checkpoint node (k3s server/control-plane)
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
log_info "Step 1: Cleaning up..."

run_kubectl "delete deployment gpu-counter 2>/dev/null || true"
run_kubectl "delete pod gpu-counter-restored 2>/dev/null || true"
run_kubectl "delete checkpoint gpu-counter-ckpt 2>/dev/null || true"
run_kubectl "delete job -l app=grit-agent 2>/dev/null || true"

# Wait for pods to be fully terminated
log_info "Waiting for pods to terminate..."
for i in {1..30}; do
    PODS=$(run_kubectl "get pods -l app=gpu-counter --no-headers 2>/dev/null" || echo "")
    [ -z "$PODS" ] && break
    sleep 2
done

run_ckpt "sudo rm -rf /mnt/grit-agent/default/ /mnt/checkpoint/default/ /tmp/ckpt-data.tar.gz" || true
run_rest "sudo rm -rf /mnt/grit-agent/default/ /mnt/checkpoint/default/ /tmp/ckpt-data.tar.gz" || true

sleep 3
log_success "Cleanup complete"

# Step 2: Get node names
log_info "Step 2: Getting node names..."

CKPT_NODE_NAME=$(echo "$CHECKPOINT_NODE" | tr '.' '-')
REST_NODE_NAME=$(echo "$RESTORE_NODE" | tr '.' '-')

log_info "Checkpoint node: $CKPT_NODE_NAME, Restore node: $REST_NODE_NAME"


# Step 3: Deploy GPU counter
log_info "Step 3: Deploying GPU counter..."

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
        kubernetes.io/hostname: $CKPT_NODE_NAME
      containers:
      - name: counter
        image: nvcr.io/nvidia/cuda:12.2.0-base-ubuntu22.04
        command: ["/bin/bash", "-c"]
        args:
        - 'step=0; while true; do step=\$((step + 10)); echo Step: \$step; nvidia-smi > /dev/null 2>&1; sleep 1; done'
        resources:
          limits:
            nvidia.com/gpu: 1
YAML

log_info "Waiting for pod..."
for i in {1..60}; do
    POD_STATUS=$(run_kubectl "get pods -l app=gpu-counter -o jsonpath='{.items[0].status.phase}'" 2>/dev/null || echo "")
    [ "$POD_STATUS" = "Running" ] && break
    sleep 2
done

[ "$POD_STATUS" != "Running" ] && { log_error "Pod failed to start"; exit 1; }

# Wait a moment for pod to stabilize, then get fresh name
sleep 3
POD_NAME=$(run_kubectl "get pods -l app=gpu-counter -o jsonpath='{.items[0].metadata.name}'")
log_success "Pod $POD_NAME running"

log_info "Waiting $WAIT_TIME seconds..."
sleep "$WAIT_TIME"

CKPT_VALUE=$(run_kubectl "logs $POD_NAME --tail=1" | grep -o 'Step: [0-9]*' | cut -d' ' -f2)
log_info "Counter at checkpoint: $CKPT_VALUE"


# Step 4: Create checkpoint
log_info "Step 4: Creating checkpoint..."

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

log_info "Waiting for checkpoint..."
for i in {1..60}; do
    PHASE=$(run_kubectl "get checkpoint gpu-counter-ckpt -o jsonpath='{.status.phase}'" 2>/dev/null || echo "")
    [ "$PHASE" = "Checkpointed" ] && break
    [ "$PHASE" = "Failed" ] && { log_error "Checkpoint failed"; exit 1; }
    sleep 2
done

[ "$PHASE" != "Checkpointed" ] && { log_error "Checkpoint timeout"; exit 1; }
log_success "Checkpoint completed"

# Step 5: Copy checkpoint data
log_info "Step 5: Copying checkpoint data..."

run_ckpt "sudo tar -czf /tmp/ckpt-data.tar.gz -C /mnt/checkpoint/default/gpu-counter-ckpt . && sudo chmod 644 /tmp/ckpt-data.tar.gz"
run_rest "scp -o StrictHostKeyChecking=no -i /tmp/inter-node-key ${SSH_USER}@${CHECKPOINT_NODE}:/tmp/ckpt-data.tar.gz /tmp/ckpt-data.tar.gz"
run_rest "sudo mkdir -p /mnt/grit-agent/default/gpu-counter-ckpt && sudo tar -xzf /tmp/ckpt-data.tar.gz -C /mnt/grit-agent/default/gpu-counter-ckpt"

log_success "Data copied"


# Step 6: Create restore pod
log_info "Step 6: Creating restore pod..."

run_kubectl "delete deployment gpu-counter"
sleep 10

# Get GPU UUIDs for device mapping
CKPT_GPU_UUID=$(run_ckpt "nvidia-smi -L | grep -oP 'UUID: \K[^)]+'" | head -1)
REST_GPU_UUID=$(run_rest "nvidia-smi -L | grep -oP 'UUID: \K[^)]+'" | head -1)
log_info "Device map: $CKPT_GPU_UUID -> $REST_GPU_UUID"

cat <<YAML | run_kubectl "apply -f -"
apiVersion: v1
kind: Pod
metadata:
  name: gpu-counter-restored
  annotations:
    grit.dev/checkpoint: "/mnt/grit-agent/default/gpu-counter-ckpt"
    grit.dev/restore-name: "gpu-counter-ckpt"
    grit.dev/device-map: "$CKPT_GPU_UUID=$REST_GPU_UUID"
spec:
  runtimeClassName: grit
  nodeSelector:
    kubernetes.io/hostname: $REST_NODE_NAME
  containers:
  - name: counter
    image: nvcr.io/nvidia/cuda:12.2.0-base-ubuntu22.04
    command: ["/bin/bash", "-c"]
    args:
    - 'step=0; while true; do step=\$((step + 10)); echo Step: \$step; nvidia-smi > /dev/null 2>&1; sleep 1; done'
    resources:
      limits:
        nvidia.com/gpu: 1
YAML

log_info "Waiting for restore pod..."
for i in {1..60}; do
    STATUS=$(run_kubectl "get pod gpu-counter-restored -o jsonpath='{.status.phase}'" 2>/dev/null || echo "")
    [ "$STATUS" = "Running" ] && break
    sleep 2
done

[ "$STATUS" != "Running" ] && { log_error "Restore pod failed"; exit 1; }
log_success "Restore pod running"


# Step 7: Verify
log_info "Step 7: Verifying restore..."
sleep 5

FIRST_LINE=$(run_kubectl "logs gpu-counter-restored | head -1")
REST_START=$(echo "$FIRST_LINE" | grep -o 'Step: [0-9]*' | cut -d' ' -f2 || echo "0")
CURRENT=$(run_kubectl "logs gpu-counter-restored --tail=1" | grep -o 'Step: [0-9]*' | cut -d' ' -f2)

echo ""
echo "==========================================="
echo "Results"
echo "==========================================="
echo "Checkpoint value:    $CKPT_VALUE"
echo "Restore start value: $REST_START"
echo "Current value:       $CURRENT"
echo ""

if [ "$REST_START" -gt 0 ] && [ "$REST_START" -ge "$((CKPT_VALUE - 200))" ]; then
    log_success "✅ RESTORE SUCCESSFUL!"
    EXIT_CODE=0
else
    log_error "❌ RESTORE FAILED!"
    EXIT_CODE=1
fi

echo ""
log_info "First 5 lines:"
run_kubectl "logs gpu-counter-restored | head -5"

# Cleanup temp files
run_ckpt "sudo rm -f /tmp/ckpt-data.tar.gz" || true
run_rest "rm -f /tmp/inter-node-key /tmp/ckpt-data.tar.gz" || true

exit $EXIT_CODE
