#!/bin/bash
set -eo pipefail

# ============================================================================
# Simple (Non-GPU) Checkpoint/Restore Test
# Tests basic CRIU checkpoint/restore without GPU complications
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

K3S_SERVER="${1:-}"
TARGET_NODE="${2:-}"
SSH_USER="${SSH_USER:-ubuntu}"
WAIT_TIME="${WAIT_TIME:-15}"

if [ -z "$K3S_SERVER" ]; then
    echo "Usage: $0 <k3s-server-ip> [target-node-ip]"
    exit 1
fi

TARGET_NODE="${TARGET_NODE:-$K3S_SERVER}"
SSH_KEY="${SSH_KEY:-~/.ssh/krish_key}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -i $SSH_KEY"

log_info "K3s server: $K3S_SERVER"
log_info "Target node: $TARGET_NODE"

run_ssh() { ssh $SSH_OPTS ${SSH_USER}@${K3S_SERVER} "$@"; }
run_target() { ssh $SSH_OPTS ${SSH_USER}@${TARGET_NODE} "$@"; }
run_kubectl() { run_ssh "kubectl $@"; }

NODE_NAME=$(echo "$TARGET_NODE" | tr '.' '-')
log_info "Target node name: $NODE_NAME"

# Cleanup
log_info "Cleaning up..."
run_kubectl "delete deployment simple-counter 2>/dev/null || true"
run_kubectl "delete pod simple-counter-restored 2>/dev/null || true"
run_kubectl "delete checkpoint simple-counter-ckpt 2>/dev/null || true"
run_kubectl "delete job -l grit.dev/helper=grit-agent 2>/dev/null || true"
run_target "sudo rm -rf /mnt/grit-agent/default/ /mnt/checkpoint/default/ /mnt/pvc-data/default/" || true
sleep 5

# Deploy simple counter (NO GPU)
log_info "Deploying simple counter (NO GPU)..."

cat <<YAML | run_kubectl "apply -f -"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: simple-counter
spec:
  replicas: 1
  selector:
    matchLabels:
      app: simple-counter
  template:
    metadata:
      labels:
        app: simple-counter
    spec:
      runtimeClassName: grit
      nodeSelector:
        kubernetes.io/hostname: $NODE_NAME
      containers:
      - name: counter
        image: ubuntu:22.04
        command: ["/bin/bash", "-c"]
        args:
        - |
          step=0
          echo "Starting simple counter..."
          while true; do
            step=\$((step + 10))
            echo "Step: \$step"
            sleep 1
          done
YAML

log_info "Waiting for pod..."
for i in {1..60}; do
    STATUS=$(run_kubectl "get pods -l app=simple-counter -o jsonpath='{.items[0].status.phase}'" 2>/dev/null || echo "")
    [ "$STATUS" = "Running" ] && break
    sleep 2
done

[ "$STATUS" != "Running" ] && { log_error "Pod failed to start"; exit 1; }
sleep 3
POD_NAME=$(run_kubectl "get pods -l app=simple-counter -o jsonpath='{.items[0].metadata.name}'")
log_success "Pod $POD_NAME running"

log_info "Waiting $WAIT_TIME seconds..."
sleep "$WAIT_TIME"

CKPT_VALUE=$(run_kubectl "logs $POD_NAME --tail=1" | grep -o 'Step: [0-9]*' | cut -d' ' -f2)
log_info "Counter at checkpoint: $CKPT_VALUE"


# Create checkpoint
log_info "Creating checkpoint..."

cat <<YAML | run_kubectl "apply -f -"
apiVersion: kaito.sh/v1alpha1
kind: Checkpoint
metadata:
  name: simple-counter-ckpt
spec:
  podName: $POD_NAME
  autoMigration: false
  volumeClaim:
    claimName: ckpt-store
YAML

log_info "Waiting for checkpoint..."
for i in {1..90}; do
    PHASE=$(run_kubectl "get checkpoint simple-counter-ckpt -o jsonpath='{.status.phase}'" 2>/dev/null || echo "")
    log_info "  Phase: $PHASE"
    [ "$PHASE" = "Checkpointed" ] && break
    [ "$PHASE" = "Failed" ] && { log_error "Checkpoint failed"; run_kubectl "describe checkpoint simple-counter-ckpt"; exit 1; }
    sleep 3
done

[ "$PHASE" != "Checkpointed" ] && { log_error "Checkpoint timeout"; exit 1; }
log_success "Checkpoint completed"


# Copy checkpoint to restore location
log_info "Copying checkpoint data..."
run_target "sudo mkdir -p /mnt/grit-agent/default/simple-counter-ckpt"
run_target "sudo cp -r /mnt/checkpoint/default/simple-counter-ckpt/* /mnt/grit-agent/default/simple-counter-ckpt/"
log_success "Data copied"


# Delete original and create restore pod
log_info "Deleting original deployment..."
run_kubectl "delete deployment simple-counter"
sleep 10

log_info "Creating restore pod..."

cat <<YAML | run_kubectl "apply -f -"
apiVersion: v1
kind: Pod
metadata:
  name: simple-counter-restored
  annotations:
    grit.dev/checkpoint: "/mnt/grit-agent/default/simple-counter-ckpt"
    grit.dev/restore-name: "simple-counter-ckpt"
spec:
  runtimeClassName: grit
  nodeSelector:
    kubernetes.io/hostname: $NODE_NAME
  containers:
  - name: counter
    image: ubuntu:22.04
    command: ["/bin/bash", "-c"]
    args:
    - |
      step=0
      echo "Starting simple counter..."
      while true; do
        step=\$((step + 10))
        echo "Step: \$step"
        sleep 1
      done
YAML

log_info "Waiting for restore pod..."
for i in {1..60}; do
    STATUS=$(run_kubectl "get pod simple-counter-restored -o jsonpath='{.status.phase}'" 2>/dev/null || echo "")
    [ "$STATUS" = "Running" ] && break
    sleep 3
done

if [ "$STATUS" != "Running" ]; then
    log_error "Restore pod failed"
    run_kubectl "describe pod simple-counter-restored"
    run_kubectl "logs simple-counter-restored" 2>/dev/null || true
    exit 1
fi

log_success "Restore pod running"


# Verify
log_info "Verifying restore..."
sleep 5

FIRST_LINE=$(run_kubectl "logs simple-counter-restored | head -5")
echo "$FIRST_LINE"

REST_START=$(echo "$FIRST_LINE" | grep -o 'Step: [0-9]*' | head -1 | cut -d' ' -f2 || echo "0")
CURRENT=$(run_kubectl "logs simple-counter-restored --tail=1" | grep -o 'Step: [0-9]*' | cut -d' ' -f2)

echo ""
echo "==========================================="
echo "RESULTS"
echo "==========================================="
echo "Checkpoint value:    $CKPT_VALUE"
echo "Restore start value: $REST_START"
echo "Current value:       $CURRENT"
echo ""

if [ -n "$REST_START" ] && [ "$REST_START" -gt 0 ] && [ "$REST_START" -ge "$((CKPT_VALUE - 200))" ]; then
    log_success "✅ SIMPLE CHECKPOINT/RESTORE SUCCESSFUL!"
    exit 0
else
    log_error "❌ RESTORE FAILED"
    exit 1
fi
