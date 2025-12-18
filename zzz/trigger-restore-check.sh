#!/bin/bash
# Trigger restore and check CRIU args

echo "=== Clear CRIU log ==="
sudo rm -f /tmp/criu-wrapper.log

echo ""
echo "=== Delete existing restore ==="
kubectl delete restore gpu-test-restore --force 2>/dev/null || true
sleep 2

echo ""
echo "=== Scale down ==="
kubectl scale deployment gpu-test --replicas=0
sleep 2

echo ""
echo "=== Create restore ==="
cat <<EOF | kubectl apply -f -
apiVersion: kaito.sh/v1alpha1
kind: Restore
metadata:
  name: gpu-test-restore
spec:
  checkpointRef:
    name: gpu-test-ckpt
  podSelector:
    matchLabels:
      pod-template-hash: 775d89fcdd
  targetReplicaSetUID: "4d67fb5f-6c78-438e-971b-d89811438a23"
EOF
sleep 2

echo ""
echo "=== Scale up ==="
kubectl scale deployment gpu-test --replicas=1

echo ""
echo "=== Wait for restore attempt ==="
for i in {1..20}; do
    sleep 2
    POD=$(kubectl get pod -l app=gpu-test -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    STATUS=$(kubectl get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)
    echo "[$i] Pod: $POD Status: $STATUS"
    
    # Check if we have CRIU logs
    if sudo test -f /tmp/criu-wrapper.log; then
        LINES=$(sudo wc -l < /tmp/criu-wrapper.log)
        echo "    CRIU log has $LINES lines"
        if [ "$LINES" -gt 3 ]; then
            break
        fi
    fi
done

echo ""
echo "=== CRIU wrapper log (what runc passed to CRIU) ==="
sudo cat /tmp/criu-wrapper.log

echo ""
echo "=== Check for ext-mount-map in CRIU args ==="
sudo grep -i "ext-mount" /tmp/criu-wrapper.log || echo "NO ext-mount-map found in CRIU args!"
