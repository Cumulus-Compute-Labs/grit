#!/bin/bash
# Check ownerRef chain

echo "=== Pod owner references ==="
kubectl get pod -l app=gpu-test -o yaml | grep -A10 ownerReferences

echo ""
echo "=== ReplicaSet owner references ==="  
RS=$(kubectl get rs -l app=gpu-test -o name | head -1)
kubectl get $RS -o yaml | grep -A10 ownerReferences

echo ""
echo "=== Deployment UID ==="
kubectl get deployment gpu-test -o jsonpath='{.metadata.uid}'
echo ""

echo ""
echo "=== ReplicaSet UID ==="
kubectl get rs -l app=gpu-test -o jsonpath='{.items[0].metadata.uid}'
echo ""
