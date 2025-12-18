#!/bin/bash
# Test GRIT Restore using the Restore CRD (not annotations)

set -e

echo "=== Testing GRIT Restore with Restore CRD ==="
echo ""

# Check if we have a checkpoint
if [ ! -d "/mnt/grit-agent/default/manual-gpu-ckpt" ]; then
    echo "❌ No checkpoint found at /mnt/grit-agent/default/manual-gpu-ckpt"
    echo "Run the manual dump script first!"
    exit 1
fi

echo "✅ Found checkpoint:"
sudo ls -lh /mnt/grit-agent/default/manual-gpu-ckpt/*.img | head -5

# Cleanup any existing restore
kubectl delete restore manual-gpu-restore 2>/dev/null || true
kubectl delete pod gpu-restored-correct 2>/dev/null || true
sleep 5

# Create Restore CRD
echo ""
echo "=== Creating Restore CRD ==="

cat <<EOF | kubectl apply -f -
apiVersion: kaito.sh/v1alpha1
kind: Restore
metadata:
  name: manual-gpu-restore
spec:
  checkpointName: manual-gpu-ckpt
  volumeClaim:
    claimName: ckpt-store
  pod:
    namespace: default
    name: gpu-restored-correct
EOF

echo ""
echo "=== Watching restore progress ==="
echo "Restore CRD created, waiting for GRIT to process it..."

# Wait for restore to start
for i in {1..60}; do
    PHASE=$(kubectl get restore manual-gpu-restore -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    echo "Restore phase: $PHASE"
    
    if [ "$PHASE" = "Restored" ]; then
        echo "✅ Restore completed!"
        break
    elif [ "$PHASE" = "Failed" ]; then
        echo "❌ Restore failed!"
        kubectl describe restore manual-gpu-restore
        exit 1
    fi
    
    sleep 3
done

# Check if pod was created
echo ""
echo "=== Checking restored pod ==="
kubectl get pod gpu-restored-correct -o wide 2>/dev/null || echo "Pod not found yet"

# Wait for pod to be running
for i in {1..60}; do
    STATUS=$(kubectl get pod gpu-restored-correct -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$STATUS" = "Running" ]; then
        echo "✅ Pod is running!"
        break
    fi
    sleep 3
done

if [ "$STATUS" = "Running" ]; then
    echo ""
    echo "=== Checking if process was truly restored ==="
    sleep 5
    
    echo "Pod logs:"
    kubectl logs gpu-restored-correct --tail=20
    
    echo ""
    echo "If you see step counters continuing from where checkpoint happened,"
    echo "then TRUE restore worked!"
else
    echo "❌ Pod not running, status: $STATUS"
    kubectl describe pod gpu-restored-correct
fi

# Check GRIT agent logs
echo ""
echo "=== GRIT Agent Logs ==="
kubectl logs -n kube-system -l app=grit-manager --tail=30 2>/dev/null | grep -i restore || echo "No restore logs found"

