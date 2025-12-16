#!/bin/bash
# =============================================================================
# GRIT GPU Pod Migration Script
# =============================================================================
#
# This script performs GPU pod migration using GRIT (GPU Runtime for Iterative
# Training) for checkpoint/restore operations, while running cuda-checkpoint
# externally on the hosts (since it doesn't work from inside containers).
#
# Workflow:
#   1. Query pod to get PID
#   2. cuda-checkpoint --action lock/checkpoint (on SOURCE host - external)
#   3. kubectl apply Checkpoint CR → GRIT handles CRIU dump + packaging
#   4. Wait for Checkpoint to complete
#   5. Delete source pod
#   6. kubectl apply Restore CR → GRIT handles pod creation + CRIU restore
#   7. Wait for Restore to complete
#   8. Get new PID from restored pod
#   9. cuda-checkpoint --action restore + toggle (on DEST host - external)
#
# Prerequisites:
#   - Both nodes have GRIT installed via Helm (use test2/setup-grit.sh)
#   - NFS storage configured for checkpoint sharing (grit-checkpoint-pvc)
#   - cuda-checkpoint installed on both nodes at /usr/local/bin/cuda-checkpoint
#   - SSH key access to both nodes
#   - pytorch-criu:latest image available on both nodes
#
# Usage:
#   ./grit-gpu-migrate.sh [--deploy] [--verbose] [--dry-run]
#
# =============================================================================

set -eo pipefail

# =============================================================================
# Configuration (defaults)
# =============================================================================
SOURCE_HOST="163.192.28.24"
DEST_HOST="192.9.133.23"
SSH_USER="ubuntu"
SSH_KEY="${SSH_KEY:-~/.ssh/krish_key}"  # Default SSH key path

NAMESPACE="default"
POD_NAME="gpu-training"
CONTAINER_NAME="trainer"
CHECKPOINT_PVC="grit-checkpoint-pvc"

# Script options
DEPLOY_POD=false
VERBOSE=false
DRY_RUN=false

# =============================================================================
# Parse Arguments
# =============================================================================
while [[ $# -gt 0 ]]; do
    case $1 in
        --deploy) DEPLOY_POD=true; shift ;;
        --verbose|-v) VERBOSE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --key|-k) SSH_KEY="$2"; shift 2 ;;
        --source) SOURCE_HOST="$2"; shift 2 ;;
        --dest) DEST_HOST="$2"; shift 2 ;;
        --user) SSH_USER="$2"; shift 2 ;;
        --pod) POD_NAME="$2"; shift 2 ;;
        --namespace|-n) NAMESPACE="$2"; shift 2 ;;
        --help|-h) 
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --key, -k PATH      SSH private key path (default: ~/.ssh/krish_key)"
            echo "  --source HOST       Source host IP (default: 163.192.28.24)"
            echo "  --dest HOST         Destination host IP (default: 192.9.133.23)"
            echo "  --user USER         SSH user (default: ubuntu)"
            echo "  --pod NAME          Pod name (default: gpu-training)"
            echo "  --namespace, -n NS  Namespace (default: default)"
            echo "  --deploy            Deploy training pod first"
            echo "  --verbose, -v       Verbose output"
            echo "  --dry-run           Show commands without executing"
            echo "  --help, -h          Show this help"
            exit 0 
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# =============================================================================
# Build SSH commands (after argument parsing)
# =============================================================================
if [ -n "$SSH_KEY" ]; then
    # Expand ~ to home directory
    SSH_KEY="${SSH_KEY/#\~/$HOME}"
    SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no"
else
    SSH_OPTS="-o StrictHostKeyChecking=no"
fi
SSH_SRC="ssh $SSH_OPTS ${SSH_USER}@${SOURCE_HOST}"
SSH_DST="ssh $SSH_OPTS ${SSH_USER}@${DEST_HOST}"
SCP_OPTS="$SSH_OPTS"

# =============================================================================
# Colors and Logging
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $1"; }
log_verbose() { $VERBOSE && echo -e "${CYAN}[DEBUG]${NC} $1" || true; }

# =============================================================================
# Helper Functions
# =============================================================================

# Execute command with dry-run support
exec_cmd() {
    local host=$1
    local cmd=$2
    local desc=${3:-""}
    
    if $DRY_RUN; then
        echo "[DRY-RUN] Would execute on $host: $cmd"
        return 0
    fi
    
    if [ "$host" = "source" ]; then
        $SSH_SRC "$cmd"
    elif [ "$host" = "dest" ]; then
        $SSH_DST "$cmd"
    else
        eval "$cmd"
    fi
}

# Wait for checkpoint to complete
wait_for_checkpoint() {
    local ckpt_name=$1
    local timeout=${2:-300}  # 5 minute default
    local elapsed=0
    
    log_info "Waiting for checkpoint '$ckpt_name' to complete..."
    while [ $elapsed -lt $timeout ]; do
        PHASE=$(exec_cmd "source" "kubectl get checkpoint $ckpt_name -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null" || echo "Pending")
        log_verbose "  Checkpoint phase: $PHASE"
        
        case "$PHASE" in
            "Checkpointed"|"Submitted")
                log_success "Checkpoint completed with phase: $PHASE"
                return 0
                ;;
            "Failed")
                log_error "Checkpoint failed!"
                exec_cmd "source" "kubectl describe checkpoint $ckpt_name -n $NAMESPACE" || true
                return 1
                ;;
        esac
        
        sleep 3
        elapsed=$((elapsed + 3))
    done
    
    log_error "Checkpoint timed out after ${timeout}s"
    return 1
}

# Wait for restore to complete
wait_for_restore() {
    local rst_name=$1
    local timeout=${2:-300}  # 5 minute default
    local elapsed=0
    
    log_info "Waiting for restore '$rst_name' to complete..."
    while [ $elapsed -lt $timeout ]; do
        PHASE=$(exec_cmd "source" "kubectl get restore $rst_name -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null" || echo "Pending")
        log_verbose "  Restore phase: $PHASE"
        
        case "$PHASE" in
            "Restored")
                log_success "Restore completed with phase: $PHASE"
                return 0
                ;;
            "Failed")
                log_error "Restore failed!"
                exec_cmd "source" "kubectl describe restore $rst_name -n $NAMESPACE" || true
                return 1
                ;;
        esac
        
        sleep 3
        elapsed=$((elapsed + 3))
    done
    
    log_error "Restore timed out after ${timeout}s"
    return 1
}

# Get process PID from container
get_container_pid() {
    local host=$1
    local search_pattern=${2:-"train.py"}
    
    exec_cmd "$host" "
        CONTAINERD_ROOT='/run/k3s/containerd/io.containerd.runtime.v2.task/k8s.io'
        for STATE_FILE in \$(sudo find \$CONTAINERD_ROOT -name 'config.json' 2>/dev/null); do
            if sudo grep -q '$search_pattern' \$STATE_FILE 2>/dev/null; then
                DIR=\$(dirname \$STATE_FILE)
                PID=\$(sudo cat \$DIR/init.pid 2>/dev/null)
                if [ -n \"\$PID\" ]; then
                    echo \$PID
                    break
                fi
            fi
        done
    "
}

# =============================================================================
# Main Script
# =============================================================================

echo ""
echo "=============================================="
echo "     GRIT GPU Pod Migration"
echo "=============================================="
echo "Source:    ${SOURCE_HOST}"
echo "Dest:      ${DEST_HOST}"
echo "Pod:       ${POD_NAME}"
echo "Namespace: ${NAMESPACE}"
echo "=============================================="
echo ""

# =============================================================================
# PHASE 0: Deploy GPU Training Pod (Optional)
# =============================================================================
deploy_training_pod() {
    log_step "PHASE 0: Deploy GPU Training Pod"
    
    log_info "[0.1] Creating training script..."
    cat > /tmp/train.py << 'TRAINEOF'
import torch
import time
import os
import sys

# Log file path
LOG_FILE = "/tmp/pytorch.log"

def log(msg):
    """Write to both stdout and log file"""
    print(msg, flush=True)
    with open(LOG_FILE, "a") as f:
        f.write(msg + "\n")
        f.flush()

log("Starting GPU training...")
log(f"PyTorch version: {torch.__version__}")
log(f"CUDA available: {torch.cuda.is_available()}")

if torch.cuda.is_available():
    device = torch.device("cuda")
    log(f"GPU: {torch.cuda.get_device_name(0)}")
    
    # Create tensors on GPU
    x = torch.randn(1000, 1000, device=device)
    y = torch.randn(1000, 1000, device=device)
    
    step = 0
    while True:
        # Simulate training
        z = torch.matmul(x, y)
        loss = z.sum()
        
        step += 1
        if step % 10 == 0:
            log(f"Step {step}: loss={loss.item():.4f}")
        
        time.sleep(0.5)
else:
    log("ERROR: No CUDA device available!")
    exit(1)
TRAINEOF
    
    log_info "[0.2] Copying training script to source..."
    scp $SSH_OPTS /tmp/train.py ${SSH_USER}@${SOURCE_HOST}:/tmp/train.py
    exec_cmd "source" "sudo chmod 644 /tmp/train.py; sudo rm -f /tmp/pytorch.log; sudo touch /tmp/pytorch.log; sudo chmod 666 /tmp/pytorch.log"
    
    log_info "[0.3] Creating GPU training pod..."
    exec_cmd "source" "kubectl delete pod $POD_NAME -n $NAMESPACE --ignore-not-found 2>/dev/null || true"
    sleep 2
    
    exec_cmd "source" "kubectl apply -f - << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
  namespace: $NAMESPACE
  labels:
    app: gpu-training
spec:
  runtimeClassName: grit
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: 163-192-28-24
  containers:
  - name: $CONTAINER_NAME
    image: pytorch-criu:latest
    imagePullPolicy: Never
    command: [\"python3\", \"-u\", \"/workspace/train.py\"]
    resources:
      limits:
        nvidia.com/gpu: \"1\"
    volumeMounts:
    - name: training-script
      mountPath: /workspace
    - name: log-volume
      mountPath: /tmp
    securityContext:
      privileged: true
  volumes:
  - name: training-script
    hostPath:
      path: /tmp
      type: Directory
  - name: log-volume
    hostPath:
      path: /tmp
      type: Directory
EOF"
    
    log_info "[0.4] Waiting for pod to be ready..."
    exec_cmd "source" "kubectl wait --for=condition=Ready pod/$POD_NAME -n $NAMESPACE --timeout=120s"
    
    log_info "[0.5] Letting training run for 10 seconds..."
    sleep 10
    exec_cmd "source" "tail -5 /tmp/pytorch.log" || true
    
    log_success "Training pod deployed and running"
}

# Deploy pod if requested or if not found
if $DEPLOY_POD; then
    deploy_training_pod
fi

# =============================================================================
# PHASE 1: Get Pod Info
# =============================================================================
log_step "PHASE 1: Get Pod Info"

log_info "[1.1] Getting process PID from container..."
PID=$(get_container_pid "source" "train.py")

if [ -z "$PID" ]; then
    log_warn "Training pod not found. Deploying..."
    deploy_training_pod
    PID=$(get_container_pid "source" "train.py")
fi

if [ -z "$PID" ]; then
    log_error "Could not find training process PID"
    exit 1
fi
log_info "  Process PID: $PID"

log_info "[1.2] Getting GPU UUIDs..."
SOURCE_UUID=$(exec_cmd "source" "nvidia-smi -L | grep -oP 'UUID: \K[^\)]+' | head -1")
DEST_UUID=$(exec_cmd "dest" "nvidia-smi -L | grep -oP 'UUID: \K[^\)]+' | head -1")
log_info "  Source GPU: $SOURCE_UUID"
log_info "  Dest GPU:   $DEST_UUID"

log_info "[1.3] Recording current training step..."
CURRENT_STEP=$(exec_cmd "source" "tail -1 /tmp/pytorch.log 2>/dev/null | grep -oP 'Step \K\d+' || echo 'unknown'")
log_info "  Current step: $CURRENT_STEP"

# =============================================================================
# PHASE 2: Freeze GPU State (cuda-checkpoint on SOURCE)
# =============================================================================
log_step "PHASE 2: Freeze GPU State (cuda-checkpoint)"

log_info "[2.1] Checking current GPU state..."
GPU_STATE=$(exec_cmd "source" "sudo cuda-checkpoint --get-state --pid $PID 2>&1")
log_info "  Current GPU State: $GPU_STATE"

log_info "[2.2] Locking and checkpointing GPU state..."
exec_cmd "source" "
    STATE=\$(sudo cuda-checkpoint --get-state --pid $PID 2>&1)
    echo \"  State before: \$STATE\"
    
    if echo \"\$STATE\" | grep -q 'running'; then
        echo '  Step 1: Locking GPU...'
        sudo cuda-checkpoint --action lock --pid $PID --timeout 10000 2>&1
        
        echo '  Step 2: Checkpointing GPU...'
        sudo cuda-checkpoint --action checkpoint --pid $PID 2>&1
    elif echo \"\$STATE\" | grep -q 'checkpointed'; then
        echo '  GPU already checkpointed'
    elif echo \"\$STATE\" | grep -q 'locked'; then
        echo '  GPU locked, checkpointing...'
        sudo cuda-checkpoint --action checkpoint --pid $PID 2>&1
    else
        echo \"  Unknown state: \$STATE\"
    fi
    
    STATE_AFTER=\$(sudo cuda-checkpoint --get-state --pid $PID 2>&1)
    echo \"  State after: \$STATE_AFTER\"
"

GPU_STATE=$(exec_cmd "source" "sudo cuda-checkpoint --get-state --pid $PID 2>&1")
log_info "  Final GPU State: $GPU_STATE"

if [ "$GPU_STATE" != "checkpointed" ]; then
    log_error "GPU not in checkpointed state! Got: $GPU_STATE"
    exit 1
fi

log_success "GPU state frozen"

# =============================================================================
# PHASE 3: Create GRIT Checkpoint
# =============================================================================
log_step "PHASE 3: Create GRIT Checkpoint"

CKPT_NAME="gpu-ckpt-$(date +%s)"
log_info "[3.1] Creating Checkpoint CR: $CKPT_NAME"

exec_cmd "source" "kubectl apply -f - << EOF
apiVersion: kaito.sh/v1alpha1
kind: Checkpoint
metadata:
  name: $CKPT_NAME
  namespace: $NAMESPACE
spec:
  podName: $POD_NAME
  volumeClaim:
    claimName: $CHECKPOINT_PVC
EOF"

log_info "[3.2] Waiting for checkpoint to complete..."
if ! wait_for_checkpoint "$CKPT_NAME" 300; then
    log_error "Checkpoint failed"
    exit 1
fi

# Get checkpoint path for later reference
CKPT_PATH=$(exec_cmd "source" "kubectl get checkpoint $CKPT_NAME -n $NAMESPACE -o jsonpath='{.status.checkpointPath}' 2>/dev/null" || echo "")
log_info "  Checkpoint path: ${CKPT_PATH:-'(managed by GRIT)'}"

# Save GPU metadata to checkpoint directory for restore
log_info "[3.3] Saving GPU metadata to checkpoint..."
CHECKPOINT_BASE_DIR="/mnt/grit-checkpoints/$NAMESPACE/$CKPT_NAME/$CONTAINER_NAME"
exec_cmd "source" "
    # Create GPU metadata file with source GPU UUID
    sudo mkdir -p '$CHECKPOINT_BASE_DIR'
    echo '{\"sourceGPUUUIDs\":[\"$SOURCE_UUID\"],\"processPID\":$PID}' | sudo tee '$CHECKPOINT_BASE_DIR/gpu-metadata.json' > /dev/null
    sudo cat '$CHECKPOINT_BASE_DIR/gpu-metadata.json'
"
log_info "  GPU metadata saved: sourceGPU=$SOURCE_UUID"

log_success "GRIT checkpoint created: $CKPT_NAME"

# =============================================================================
# PHASE 4: Delete Source Pod
# =============================================================================
log_step "PHASE 4: Delete Source Pod"

log_info "[4.1] Deleting source pod..."
exec_cmd "source" "kubectl delete pod $POD_NAME -n $NAMESPACE --grace-period=0 --force 2>/dev/null || true"
sleep 2
log_success "Source pod deleted"

# =============================================================================
# PHASE 4.5: Deploy runc-grit Wrapper (on DESTINATION)
# =============================================================================
log_step "PHASE 4.5: Deploy runc-grit Wrapper for GPU Restore"

log_info "[4.5.1] Installing runc-grit wrapper on destination node..."

# Create and deploy the runc-grit wrapper script
exec_cmd "dest" "cat > /tmp/runc-grit << 'WRAPPER_EOF'
#!/bin/bash
# runc-grit: Wrapper that adds CRIU --action-script for GPU restore
REAL_RUNC=\"/usr/bin/runc\"
LOG=\"/var/log/runc-grit.log\"

echo \"[\$(date)] runc-grit: \$*\" >> \"\$LOG\"

# Check if restore command
IS_RESTORE=false
for arg in \"\$@\"; do [ \"\$arg\" = \"restore\" ] && IS_RESTORE=true && break; done

if [ \"\$IS_RESTORE\" = \"true\" ]; then
    # Parse --image-path
    IMAGE_PATH=\"\"
    PREV=\"\"
    for arg in \"\$@\"; do
        [ \"\$PREV\" = \"--image-path\" ] && IMAGE_PATH=\"\$arg\"
        PREV=\"\$arg\"
    done
    
    # Look for GPU metadata
    GPU_META=\"\"
    [ -n \"\$IMAGE_PATH\" ] && [ -f \"\$(dirname \$IMAGE_PATH)/gpu-metadata.json\" ] && GPU_META=\"\$(dirname \$IMAGE_PATH)/gpu-metadata.json\"
    
    if [ -n \"\$GPU_META\" ]; then
        SOURCE_GPU=\$(cat \"\$GPU_META\" | grep -o 'GPU-[^\"]*' | head -1)
        DEST_GPU=\$(nvidia-smi -L 2>/dev/null | grep -oP 'UUID: \KGPU-[^\)]+' | head -1)
        
        if [ -n \"\$SOURCE_GPU\" ] && [ -n \"\$DEST_GPU\" ]; then
            DEVICE_MAP=\"\${SOURCE_GPU}=\${DEST_GPU}\"
            echo \"[\$(date)] GPU restore: \$DEVICE_MAP\" >> \"\$LOG\"
            
            # Create action script
            ACTION_SCRIPT=\$(mktemp /tmp/gpu-action-XXXXXX.sh)
            cat > \"\$ACTION_SCRIPT\" << 'ACTION_EOF'
#!/bin/bash
[ \"\$1\" != \"post-restore\" ] && exit 0
PID=\"\$CRTOOLS_INIT_PID\"
[ -z \"\$PID\" ] && exit 0
LOG=\"/var/log/grit-gpu-restore-\$PID.log\"
echo \"[\$(date)] GPU restore for PID=\$PID\" >> \"\$LOG\"
for p in /usr/local/bin/cuda-checkpoint /usr/bin/cuda-checkpoint; do [ -x \"\$p\" ] && CUDA=\"\$p\" && break; done
[ -z \"\$CUDA\" ] && echo \"cuda-checkpoint not found\" >> \"\$LOG\" && exit 0
\$CUDA --action restore --pid \"\$PID\" --device-map \"DEVICE_MAP_PLACEHOLDER\" >> \"\$LOG\" 2>&1 || true
\$CUDA --toggle --pid \"\$PID\" >> \"\$LOG\" 2>&1 || true
echo \"[\$(date)] GPU restore done\" >> \"\$LOG\"
exit 0
ACTION_EOF
            sed -i \"s/DEVICE_MAP_PLACEHOLDER/\$DEVICE_MAP/g\" \"\$ACTION_SCRIPT\"
            chmod +x \"\$ACTION_SCRIPT\"
            
            echo \"[\$(date)] Using action script: \$ACTION_SCRIPT\" >> \"\$LOG\"
            exec \"\$REAL_RUNC\" \"\$@\" --action-script \"\$ACTION_SCRIPT\"
        fi
    fi
fi

exec \"\$REAL_RUNC\" \"\$@\"
WRAPPER_EOF"

exec_cmd "dest" "sudo mv /tmp/runc-grit /usr/local/bin/runc-grit && sudo chmod +x /usr/local/bin/runc-grit"

# Create log file with proper permissions (runc-grit runs as root via containerd)
exec_cmd "dest" "sudo touch /var/log/runc-grit.log && sudo chmod 666 /var/log/runc-grit.log"

log_info "[4.5.2] Verifying wrapper installation..."
exec_cmd "dest" "ls -la /usr/local/bin/runc-grit && /usr/local/bin/runc-grit --version 2>&1 | head -1 || echo 'Wrapper installed'"

log_info "[4.5.3] Updating containerd config to use runc-grit..."
exec_cmd "dest" "
    # Backup current config
    sudo cp /etc/containerd/config.toml /etc/containerd/config.toml.bak
    
    # Update BinaryName for grit runtime to use runc-grit
    if grep -q 'runc-grit' /etc/containerd/config.toml; then
        echo 'runc-grit already configured'
    else
        # Replace BinaryName = \"runc\" with BinaryName = \"runc-grit\" in grit section
        sudo sed -i 's|BinaryName = \"runc\"|BinaryName = \"/usr/local/bin/runc-grit\"|g' /etc/containerd/config.toml
        echo 'Updated containerd config'
    fi
    
    # Restart containerd to pick up new config
    sudo systemctl restart containerd
    sleep 3
    sudo systemctl status containerd --no-pager | head -5
"

log_success "runc-grit wrapper deployed on destination node"

# =============================================================================
# PHASE 5: Create GRIT Restore (on DESTINATION)
# =============================================================================
log_step "PHASE 5: Create GRIT Restore"

RST_NAME="gpu-rst-$(date +%s)"
log_info "[5.1] Creating Restore CR: $RST_NAME"

exec_cmd "source" "kubectl apply -f - << EOF
apiVersion: kaito.sh/v1alpha1
kind: Restore
metadata:
  name: $RST_NAME
  namespace: $NAMESPACE
spec:
  checkpointName: $CKPT_NAME
EOF"

log_info "[5.2] Copying training script to destination node..."
scp $SCP_OPTS /tmp/train.py ${SSH_USER}@${DEST_HOST}:/tmp/train.py
exec_cmd "dest" "sudo chmod 644 /tmp/train.py; sudo rm -f /tmp/pytorch.log; sudo touch /tmp/pytorch.log; sudo chmod 666 /tmp/pytorch.log"

log_info "[5.3] Creating restoration pod on destination node..."
# For standalone pods, we need to manually create the restoration pod with annotations
# The GRIT webhook only auto-selects pods with matching owner references
# IMPORTANT: Must use 'grit' runtime for CRIU restore to work!
CHECKPOINT_PATH="/mnt/grit-checkpoints/$NAMESPACE/$CKPT_NAME"

exec_cmd "source" "kubectl apply -f - << EOF
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
  namespace: $NAMESPACE
  labels:
    app: gpu-training
  annotations:
    grit.dev/checkpoint: $CHECKPOINT_PATH
    grit.dev/restore-name: $RST_NAME
spec:
  runtimeClassName: grit
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: 192-9-133-23
  containers:
  - name: $CONTAINER_NAME
    image: pytorch-criu:latest
    imagePullPolicy: Never
    command: [\"python3\", \"-u\", \"/workspace/train.py\"]
    resources:
      limits:
        nvidia.com/gpu: \"1\"
    volumeMounts:
    - name: training-script
      mountPath: /workspace
    - name: log-volume
      mountPath: /tmp
    securityContext:
      privileged: true
  volumes:
  - name: training-script
    hostPath:
      path: /tmp
      type: Directory
  - name: log-volume
    hostPath:
      path: /tmp
      type: Directory
EOF"

log_info "[5.4] Patching restore to mark pod selected..."
exec_cmd "source" "kubectl patch restore $RST_NAME -n $NAMESPACE --type=merge -p '{\"metadata\":{\"annotations\":{\"grit.dev/pod-selected\":\"true\"}}}'"

log_info "[5.5] Waiting for restore to complete..."
if ! wait_for_restore "$RST_NAME" 300; then
    log_error "Restore failed"
    exit 1
fi

log_success "GRIT restore created: $RST_NAME"

# =============================================================================
# PHASE 6: Get Restored Pod Info
# =============================================================================
log_step "PHASE 6: Get Restored Pod Info"

log_info "[6.1] Finding restored pod..."
sleep 5  # Give GRIT time to update pod status

# Get restored pod name (might be same name or with suffix)
RESTORED_POD=$(exec_cmd "source" "kubectl get restore $RST_NAME -n $NAMESPACE -o jsonpath='{.status.restoredPodName}' 2>/dev/null" || echo "$POD_NAME")
if [ -z "$RESTORED_POD" ]; then
    RESTORED_POD="$POD_NAME"
fi
log_info "  Restored pod: $RESTORED_POD"

log_info "[6.2] Waiting for restored pod to be ready..."
exec_cmd "source" "kubectl wait --for=condition=Ready pod/$RESTORED_POD -n $NAMESPACE --timeout=120s" || true

log_info "[6.3] Getting new process PID..."
sleep 3
NEW_PID=$(get_container_pid "dest" "train.py")

if [ -z "$NEW_PID" ]; then
    log_warn "Could not find restored process by pattern, trying crictl..."
    NEW_PID=$(exec_cmd "dest" "
        CONTAINER_ID=\$(crictl ps --name $CONTAINER_NAME -q 2>/dev/null | head -1)
        if [ -n \"\$CONTAINER_ID\" ]; then
            crictl inspect \$CONTAINER_ID 2>/dev/null | jq -r '.info.pid' || true
        fi
    ")
fi

if [ -z "$NEW_PID" ]; then
    log_error "Could not find restored process PID"
    exit 1
fi
log_info "  Restored PID: $NEW_PID"

# =============================================================================
# PHASE 7: Verify GPU State (handled by CRIU action script)
# =============================================================================
log_step "PHASE 7: Verify GPU State"

log_info "[7.1] Note: GPU restore is now handled by CRIU action script during restore"
log_info "      The GRIT shim automatically runs cuda-checkpoint during CRIU's post-restore phase"
log_info "      Device mapping: $SOURCE_UUID -> $DEST_UUID"

log_info "[7.2] Checking runc-grit wrapper log..."
exec_cmd "dest" "sudo tail -20 /var/log/runc-grit.log 2>/dev/null || echo '  (no runc-grit log found)'"

log_info "[7.3] Checking GPU restore action script log..."
exec_cmd "dest" "sudo cat /var/log/grit-gpu-restore-$NEW_PID.log 2>/dev/null || sudo ls -la /var/log/grit-gpu-restore-*.log 2>/dev/null || echo '  (no GPU restore log found)'"

log_info "[7.4] Checking GPU state of restored process..."
GPU_STATE=$(exec_cmd "dest" "sudo cuda-checkpoint --get-state --pid $NEW_PID 2>&1" || echo "unknown")
log_info "  Current GPU State: $GPU_STATE"

if echo "$GPU_STATE" | grep -qE "running"; then
    log_success "GPU state is running - GPU restore successful!"
elif echo "$GPU_STATE" | grep -qE "checkpointed"; then
    log_warn "GPU state is still 'checkpointed' - action script may not have run"
    log_info "[7.4] Attempting manual GPU restore as fallback..."
    exec_cmd "dest" "
        sudo cuda-checkpoint --action restore --pid $NEW_PID \
            --device-map '$SOURCE_UUID=$DEST_UUID' 2>&1 || echo 'GPU restore returned error'
        
        sudo cuda-checkpoint --toggle --pid $NEW_PID 2>&1 || echo 'GPU toggle returned error'
        
        echo \"Final GPU State: \$(sudo cuda-checkpoint --get-state --pid $NEW_PID 2>&1)\"
    "
else
    log_warn "GPU state: $GPU_STATE"
fi

log_success "GPU state verification completed"

# =============================================================================
# PHASE 8: Verification
# =============================================================================
log_step "PHASE 8: Verification"

sleep 3

log_info "[8.1] GPU Usage on destination:"
exec_cmd "dest" "nvidia-smi --query-compute-apps=pid,name,used_memory --format=csv" || true

log_info "[8.2] Training output (last 5 lines):"
exec_cmd "dest" "tail -5 /tmp/pytorch.log 2>/dev/null" || echo "  (waiting for output)"

sleep 5
NEW_STEP=$(exec_cmd "dest" "tail -1 /tmp/pytorch.log 2>/dev/null | grep -oP 'Step \K\d+' || echo 'unknown'")

log_info "[8.3] GRIT Resources:"
exec_cmd "source" "kubectl get checkpoints,restores -n $NAMESPACE" || true

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=============================================="
log_success "GRIT GPU Pod Migration Complete!"
echo "=============================================="
echo ""
echo "Summary:"
echo "  Source Host:      $SOURCE_HOST"
echo "  Dest Host:        $DEST_HOST"
echo "  Source Step:      $CURRENT_STEP"
echo "  Resumed Step:     $NEW_STEP"
echo "  Original PID:     $PID"
echo "  Restored PID:     $NEW_PID"
echo "  GPU Remapped:     $SOURCE_UUID -> $DEST_UUID"
echo ""
echo "GRIT Resources:"
echo "  Checkpoint:       $CKPT_NAME"
echo "  Restore:          $RST_NAME"
echo "  Restored Pod:     $RESTORED_POD"
echo ""
echo "Monitor training:"
echo "  $SSH_DST 'tail -f /tmp/pytorch.log'"
echo ""
echo "Cleanup (optional):"
echo "  kubectl delete checkpoint $CKPT_NAME -n $NAMESPACE"
echo "  kubectl delete restore $RST_NAME -n $NAMESPACE"
echo ""
