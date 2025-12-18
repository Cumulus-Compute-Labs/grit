#!/bin/bash
set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

CHECKPOINT_NODE="${1:-}"
RESTORE_NODE="${2:-}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-}"
WAIT_TIME="${WAIT_TIME:-20}"

if [ -z "$CHECKPOINT_NODE" ] || [ -z "$RESTORE_NODE" ]; then
    echo "Usage: $0 <checkpoint-node-ip> <restore-node-ip>"
    echo "Environment variables: SSH_USER (default: ubuntu), SSH_KEY (path to private key)"
    exit 1
fi

SSH_KEY_OPT=""
[ -n "$SSH_KEY" ] && SSH_KEY_OPT="-i $SSH_KEY"

SSH_OPTS="$SSH_KEY_OPT -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
SCP_OPTS="$SSH_KEY_OPT -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

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
log_info "Step 1: Cleaning up..."

run_kubectl "delete deployment gpu-counter 2>/dev/null || true"
run_kubectl "delete restore gpu-counter-restore 2>/dev/null || true"
run_kubectl "delete checkpoint gpu-counter-ckpt 2>/dev/null || true"
run_kubectl "delete job -l app=grit-agent 2>/dev/null || true"

run_ckpt "sudo rm -rf /mnt/grit-agent/default/ /mnt/checkpoint/default/ /tmp/ckpt-data.tar.gz" || true
run_rest "sudo rm -rf /mnt/grit-agent/default/ /mnt/checkpoint/default/ /tmp/ckpt-data.tar.gz" || true

sleep 3
log_success "Cleanup complete"

# Step 2: Get node names
log_info "Step 2: Getting node names..."

CKPT_NODE_NAME=$(echo "$CHECKPOINT_NODE" | tr '.' '-')
REST_NODE_NAME=$(echo "$RESTORE_NODE" | tr '.' '-')

log_info "Checkpoint k8s node: $CKPT_NODE_NAME"
log_info "Restore k8s node: $REST_NODE_NAME"

# Step 3: Deploy GPU counter on checkpoint node
log_info "Step 3: Deploying GPU counter on checkpoint node..."

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
        image: nvidia/cuda:12.0.0-base-ubuntu22.04
        command: ["/bin/bash", "-c"]
        args:
        - 'i=0; while true; do echo "Counter: \$i"; i=\$((i+1)); sleep 1; done'
        resources:
          limits:
            nvidia.com/gpu: 1
YAML

log_info "Waiting for pod..."
for i in {1..90}; do
    POD_STATUS=$(run_kubectl "get pods -l app=gpu-counter -o jsonpath='{.items[0].status.phase}'" 2>/dev/null || echo "")
    [ "$POD_STATUS" = "Running" ] && break
    sleep 2
done

if [ "$POD_STATUS" != "Running" ]; then
    log_error "Pod failed to start"
    run_kubectl "get pods -l app=gpu-counter"
    run_kubectl "describe pods -l app=gpu-counter" | tail -30
    exit 1
fi

POD_NAME=$(run_kubectl "get pods -l app=gpu-counter -o jsonpath='{.items[0].metadata.name}'")
log_success "Pod $POD_NAME running"

log_info "Waiting $WAIT_TIME seconds for counter to increment..."
sleep "$WAIT_TIME"

CKPT_VALUE=$(run_kubectl "logs $POD_NAME --tail=1" | grep -o 'Counter: [0-9]*' | cut -d' ' -f2 || echo "0")
log_info "Counter at checkpoint time: $CKPT_VALUE"

# Step 4: Create checkpoint
log_info "Step 4: Creating checkpoint..."

cat <<YAML | run_kubectl "apply -f -"
apiVersion: kaito.sh/v1alpha1
kind: Checkpoint
metadata:
  name: gpu-counter-ckpt
spec:
  podName: $POD_NAME
  volumeClaim:
    claimName: ckpt-store
YAML

log_info "Waiting for checkpoint to complete..."
for i in {1..90}; do
    PHASE=$(run_kubectl "get checkpoint gpu-counter-ckpt -o jsonpath='{.status.phase}'" 2>/dev/null || echo "")
    [ "$PHASE" = "Checkpointed" ] && break
    if [ "$PHASE" = "Failed" ]; then
        log_error "Checkpoint failed!"
        run_kubectl "describe checkpoint gpu-counter-ckpt"
        exit 1
    fi
    sleep 2
done

if [ "$PHASE" != "Checkpointed" ]; then
    log_error "Checkpoint timeout (phase: $PHASE)"
    run_kubectl "describe checkpoint gpu-counter-ckpt"
    run_kubectl "get jobs"
    run_kubectl "logs job/grit-agent-gpu-counter-ckpt 2>/dev/null || true"
    exit 1
fi

log_success "Checkpoint completed!"
run_kubectl "get checkpoint gpu-counter-ckpt"

# Step 5: Get ReplicaSet info for Restore
log_info "Step 5: Getting ReplicaSet info for Restore..."

RS_NAME=$(run_kubectl "get rs -l app=gpu-counter -o jsonpath='{.items[0].metadata.name}'")
RS_UID=$(run_kubectl "get rs -l app=gpu-counter -o jsonpath='{.items[0].metadata.uid}'")

log_info "ReplicaSet: $RS_NAME (UID: $RS_UID)"

# Step 6: Create Restore CR
log_info "Step 6: Creating Restore CR..."

cat <<YAML | run_kubectl "apply -f -"
apiVersion: kaito.sh/v1alpha1
kind: Restore
metadata:
  name: gpu-counter-restore
spec:
  checkpointName: gpu-counter-ckpt
  ownerRef:
    apiVersion: apps/v1
    kind: ReplicaSet
    name: $RS_NAME
    uid: $RS_UID
YAML

log_success "Restore CR created"

# Step 7: Delete and recreate pod to trigger restore
log_info "Step 7: Triggering restore by deleting current pod..."

run_kubectl "delete pod -l app=gpu-counter"
sleep 5

log_info "Waiting for new pod to be created and restored..."
for i in {1..90}; do
    RESTORE_PHASE=$(run_kubectl "get restore gpu-counter-restore -o jsonpath='{.status.phase}'" 2>/dev/null || echo "")
    POD_STATUS=$(run_kubectl "get pods -l app=gpu-counter -o jsonpath='{.items[0].status.phase}'" 2>/dev/null || echo "")
    
    if [ "$RESTORE_PHASE" = "Restored" ] && [ "$POD_STATUS" = "Running" ]; then
        break
    fi
    if [ "$RESTORE_PHASE" = "Failed" ]; then
        log_error "Restore failed!"
        run_kubectl "describe restore gpu-counter-restore"
        break
    fi
    sleep 2
done

# Step 8: Show results
echo ""
echo "==========================================="
echo "Results"
echo "==========================================="

run_kubectl "get restore gpu-counter-restore"
echo ""
run_kubectl "get pods -l app=gpu-counter"
echo ""

NEW_POD=$(run_kubectl "get pods -l app=gpu-counter -o jsonpath='{.items[0].metadata.name}'" 2>/dev/null || echo "")
if [ -n "$NEW_POD" ]; then
    POD_STATUS=$(run_kubectl "get pod $NEW_POD -o jsonpath='{.status.phase}'")
    
    if [ "$POD_STATUS" = "Running" ]; then
        log_success "Pod is running!"
        CURRENT_VALUE=$(run_kubectl "logs $NEW_POD --tail=1" | grep -o 'Counter: [0-9]*' | cut -d' ' -f2 || echo "0")
        FIRST_LINE=$(run_kubectl "logs $NEW_POD | head -1")
        REST_START=$(echo "$FIRST_LINE" | grep -o 'Counter: [0-9]*' | cut -d' ' -f2 || echo "0")
        
        echo ""
        echo "Checkpoint value:     $CKPT_VALUE"
        echo "Restore start value:  $REST_START"  
        echo "Current value:        $CURRENT_VALUE"
        echo ""
        
        if [ "$REST_START" -gt 0 ] && [ "$REST_START" -ge "$((CKPT_VALUE - 50))" ]; then
            log_success "✅ RESTORE SUCCESSFUL! Counter resumed from checkpoint."
            EXIT_CODE=0
        else
            log_warn "⚠️ Pod running but counter started from 0 (restore may have failed)"
            log_warn "This is expected if using CRIU 3.x without cuda-checkpoint"
            EXIT_CODE=1
        fi
        
        echo ""
        log_info "First 5 lines of logs:"
        run_kubectl "logs $NEW_POD | head -5"
        
    elif [ "$POD_STATUS" = "CrashLoopBackOff" ] || [ "$POD_STATUS" = "Error" ]; then
        log_error "❌ Pod failed to start after restore"
        log_warn "This usually means CRIU restore failed"
        log_warn "GPU checkpoint/restore requires CRIU 4.0+ with cuda-checkpoint"
        echo ""
        run_kubectl "describe pod $NEW_POD | tail -20"
        EXIT_CODE=1
    else
        log_warn "Pod status: $POD_STATUS"
        EXIT_CODE=1
    fi
else
    log_error "No pod found"
    EXIT_CODE=1
fi

# Cleanup temp files
run_ckpt "sudo rm -f /tmp/ckpt-data.tar.gz" 2>/dev/null || true
run_rest "rm -f /tmp/inter-node-key /tmp/ckpt-data.tar.gz" 2>/dev/null || true

exit ${EXIT_CODE:-1}
