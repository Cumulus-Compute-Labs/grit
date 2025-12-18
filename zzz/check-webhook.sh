#!/bin/bash
# Check webhook status

echo "=== Grit manager in kube-system ==="
kubectl get pods -n kube-system | grep grit

echo ""
echo "=== Grit manager logs (webhook/restore/pod related) ==="
kubectl logs -n kube-system deployment/grit-manager --tail=50 2>&1 | grep -iE "webhook|restore|pod|mutate" || echo "No matching logs"

echo ""
echo "=== Webhook service endpoint ==="
kubectl get endpoints -n kube-system grit-manager-webhook-svc

echo ""
echo "=== Test webhook directly ==="
# Check if webhook server is responding
kubectl run webhook-test --image=curlimages/curl --restart=Never --rm -i --timeout=10s -- \
    curl -k -s -o /dev/null -w "%{http_code}" https://grit-manager-webhook-svc.kube-system.svc:443/healthz 2>/dev/null || echo "Webhook health check failed or timed out"
