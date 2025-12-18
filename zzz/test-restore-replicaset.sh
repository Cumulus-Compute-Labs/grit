#!/bin/bash
# Test restore with ReplicaSet ownerRef (correct approach)

set -e

echo "=== Cleanup ==="
kubectl delete pod gpu-test-restored --force 2>/dev/null || true
kubectl delete restore gpu-test-restore --force 2>/dev/null || true
sleep 2

# Get ReplicaSet info
RS_NAME=$(kubectl get rs -l app=gpu-test -o jsonpath='{.items[0].metadata.name}')
RS_UID=$(kubectl get rs -l app=gpu-test -o jsonpath='{.items[0].metadata.uid}')

echo "ReplicaSet name: $RS_NAME"
echo "ReplicaSet UID: $RS_UID"

echo ""
echo "=== Delete existing deployment pod ==="
kubectl scale deployment gpu-test --replicas=0
sleep 3

echo ""
echo "=== Step 1: Create Restore CRD with ReplicaSet ownerRef ==="
cat <<EOF | kubectl apply -f -
apiVersion: kaito.sh/v1alpha1
kind: Restore
metadata:
  name: gpu-test-restore
  namespace: default
spec:
  checkpointName: gpu-test-ckpt
  ownerRef:
    apiVersion: apps/v1
    kind: ReplicaSet
    name: $RS_NAME
    uid: $RS_UID
EOF

sleep 2
echo ""
echo "Restore CRD created"
kubectl get restore gpu-test-restore

echo ""
echo "=== Step 2: Scale deployment back up (creates pod with RS ownerRef) ==="
kubectl scale deployment gpu-test --replicas=1

echo ""
echo "=== Step 3: Monitor Restore ==="
for i in {1..30}; do
    echo ""
    echo "--- Iteration $i ---"
    
    # Check restore status
    RESTORE_PHASE=$(kubectl get restore gpu-test-restore -o jsonpath='{.status.phase}' 2>/dev/null)
    echo "Restore phase: $RESTORE_PHASE"
    
    # Check restore pod-selected annotation
    POD_SELECTED=$(kubectl get restore gpu-test-restore -o jsonpath='{.metadata.annotations.grit\.dev/pod-selected}' 2>/dev/null)
    echo "Pod selected: $POD_SELECTED"
    
    # Check pod status
    POD_NAME=$(kubectl get pod -l app=gpu-test -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    POD_STATUS=$(kubectl get pod $POD_NAME -o jsonpath='{.status.phase}' 2>/dev/null)
    echo "Pod: $POD_NAME - Status: $POD_STATUS"
    
    # Check if pod has checkpoint annotation
    CKPT_ANNOTATION=$(kubectl get pod $POD_NAME -o jsonpath='{.metadata.annotations.grit\.dev/checkpoint}' 2>/dev/null)
    echo "Checkpoint annotation: $CKPT_ANNOTATION"
    
    # Check for grit jobs
    JOBS=$(kubectl get jobs -A 2>/dev/null | grep -i grit || echo "none")
    echo "Grit jobs: $JOBS"
    
    if [ "$POD_STATUS" = "Running" ] || [ "$RESTORE_PHASE" = "Restored" ]; then
        echo ""
        echo "=== Progress! ==="
        break
    fi
    
    if [ "$POD_STATUS" = "Failed" ]; then
        echo ""
        echo "=== Pod Failed ==="
        break
    fi
    
    sleep 3
done

echo ""
echo "=== Final State ==="
kubectl describe restore gpu-test-restore

echo ""
echo "=== Grit Manager Logs (recent) ==="
kubectl logs -n kube-system deployment/grit-manager --tail=30 | grep -iE "select|restore|pod|webhook" || echo "No matching logs"
