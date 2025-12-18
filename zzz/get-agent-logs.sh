#!/bin/bash
kubectl get pods
echo
POD=$(kubectl get pods -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep grit-agent | head -1)
echo "Getting logs from: $POD"
kubectl logs $POD 2>/dev/null | tail -30
