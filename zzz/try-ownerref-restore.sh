#!/bin/bash
# Try restore with ownerRef

# Get deployment UID
DEPLOY_UID=$(kubectl get deployment gpu-test -o jsonpath='{.metadata.uid}')
echo "Deployment UID: $DEPLOY_UID"

# Delete old restore
kubectl delete restore gpu-test-restore --force 2>/dev/null || true
sleep 2

# Create restore with ownerRef
cat <<EOF | kubectl apply -f -
apiVersion: kaito.sh/v1alpha1
kind: Restore
metadata:
  name: gpu-test-restore
spec:
  checkpointName: gpu-test-ckpt
  ownerRef:
    apiVersion: apps/v1
    kind: Deployment
    name: gpu-test
    uid: $DEPLOY_UID
EOF

echo ""
echo "=== Waiting for restore ==="
for i in {1..20}; do
    PHASE=$(kubectl get restore gpu-test-restore -o jsonpath='{.status.phase}' 2>/dev/null)
    echo "[$i] Phase: $PHASE"
    if [ "$PHASE" = "Restored" ] || [ "$PHASE" = "Failed" ] || [ "$PHASE" = "Restoring" ]; then
        break
    fi
    sleep 3
done

echo ""
echo "=== Restore Status ==="
kubectl describe restore gpu-test-restore

echo ""
echo "=== Grit Jobs ==="
kubectl get jobs -A | grep grit || echo "No grit jobs"
