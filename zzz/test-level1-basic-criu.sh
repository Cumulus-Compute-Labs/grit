#!/bin/bash
set -eo pipefail

# =============================================================================
# Level 1: Basic CRIU Test (NO GPU)
# Tests if GRIT checkpoint/restore works at all with a simple container
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

NODE_IP="${1:-192.9.150.56}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-~/.ssh/krish_key}"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -i $SSH_KEY"

log_info "=== Level 1: Basic CRIU Test (No GPU) ==="
log_info "K3s Server: $NODE_IP"

run_ssh() { ssh $SSH_OPTS ${SSH_USER}@${NODE_IP} "$@"; }
run_kubectl() { run_ssh "kubectl $@"; }

# Use the K3S SERVER node for everything (checkpoint data will be local)
NODE_NAME=$(echo "$NODE_IP" | tr '.' '-')
log_info "Target node: $NODE_NAME"

# Cleanup
log_info "Cleaning up..."
run_kubectl "delete deployment simple-counter 2>/dev/null || true"
run_kubectl "delete pod simple-restored 2>/dev/null || true"
run_kubectl "delete checkpoint simple-ckpt 2>/dev/null || true"
run_kubectl "delete job -l grit.dev/helper=grit-agent 2>/dev/null || true"
run_ssh "sudo rm -rf /mnt/grit-agent/default/ /mnt/checkpoint/default/ /mnt/pvc-data/default/" || true
sleep 5

# Deploy simple counter (NO GPU!)
log_info "Deploying simple counter (NO GPU)..."
cat << EOF | run_kubectl "apply -f -"
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
        image: alpine:latest
        command: ["/bin/sh", "-c"]
        args:
        - |
          i=0
          while true; do
            i=\$((i + 10))
            echo "Step: \$i"
            sleep 1
          done
EOF

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

log_info "Letting counter run for 15 seconds..."
sleep 15

CKPT_VALUE=$(run_kubectl "logs $POD_NAME --tail=1" | grep -o 'Step: [0-9]*' | cut -d' ' -f2)
log_info "Counter at checkpoint: $CKPT_VALUE"

# Create checkpoint
log_info "Creating checkpoint..."
cat << EOF | run_kubectl "apply -f -"
apiVersion: kaito.sh/v1alpha1
kind: Checkpoint
metadata:
  name: simple-ckpt
spec:
  podName: $POD_NAME
  autoMigration: false
  volumeClaim:
    claimName: ckpt-store
EOF

log_info "Waiting for checkpoint..."
for i in {1..90}; do
    PHASE=$(run_kubectl "get checkpoint simple-ckpt -o jsonpath='{.status.phase}'" 2>/dev/null || echo "")
    echo "  Phase: $PHASE"
    [ "$PHASE" = "Checkpointed" ] && break
    [ "$PHASE" = "Failed" ] && { 
        log_error "Checkpoint failed!"
        run_kubectl "describe checkpoint simple-ckpt"
        run_kubectl "logs job/grit-agent-simple-ckpt" 2>/dev/null || true
        exit 1
    }
    sleep 3
done

[ "$PHASE" != "Checkpointed" ] && { log_error "Checkpoint timeout"; exit 1; }
log_success "Checkpoint completed!"

# Copy checkpoint to restore location
log_info "Copying checkpoint data..."
run_ssh "sudo mkdir -p /mnt/grit-agent/default/simple-ckpt"
run_ssh "sudo cp -r /mnt/checkpoint/default/simple-ckpt/* /mnt/grit-agent/default/simple-ckpt/"

# Delete original
log_info "Deleting original deployment..."
run_kubectl "delete deployment simple-counter"
sleep 10

# Create restore pod
log_info "Creating restore pod..."
cat << EOF | run_kubectl "apply -f -"
apiVersion: v1
kind: Pod
metadata:
  name: simple-restored
  annotations:
    grit.dev/checkpoint: "/mnt/grit-agent/default/simple-ckpt"
    grit.dev/restore-name: "simple-ckpt"
spec:
  runtimeClassName: grit
  nodeSelector:
    kubernetes.io/hostname: $NODE_NAME
  containers:
  - name: counter
    image: alpine:latest
    command: ["/bin/sh", "-c"]
    args:
    - |
      i=0
      while true; do
        i=\$((i + 10))
        echo "Step: \$i"
        sleep 1
      done
EOF

log_info "Waiting for restore pod..."
for i in {1..60}; do
    STATUS=$(run_kubectl "get pod simple-restored -o jsonpath='{.status.phase}'" 2>/dev/null || echo "")
    [ "$STATUS" = "Running" ] && break
    sleep 3
done

if [ "$STATUS" != "Running" ]; then
    log_error "Restore pod failed"
    run_kubectl "describe pod simple-restored"
    exit 1
fi
log_success "Restore pod running"

# Verify
log_info "Verifying restore..."
sleep 5

FIRST_LOG=$(run_kubectl "logs simple-restored | head -3")
echo "$FIRST_LOG"

REST_START=$(echo "$FIRST_LOG" | grep -o 'Step: [0-9]*' | head -1 | cut -d' ' -f2 || echo "0")
CURRENT=$(run_kubectl "logs simple-restored --tail=1" | grep -o 'Step: [0-9]*' | cut -d' ' -f2)

echo ""
echo "==========================================="
echo "RESULTS"
echo "==========================================="
echo "Checkpoint value:    $CKPT_VALUE"
echo "Restore start:       $REST_START"  
echo "Current value:       $CURRENT"
echo ""

if [ -n "$REST_START" ] && [ "$REST_START" -gt 0 ] && [ "$REST_START" -ge "$((CKPT_VALUE - 50))" ]; then
    log_success "✅ LEVEL 1 PASSED - Basic CRIU works!"
    log_info "Counter resumed from ~$REST_START (checkpoint was at $CKPT_VALUE)"
    exit 0
else
    log_error "❌ LEVEL 1 FAILED"
    log_error "Counter started from $REST_START instead of ~$CKPT_VALUE"
    exit 1
fi

