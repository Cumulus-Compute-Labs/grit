#!/bin/bash
# Find and show recent CRIU logs

echo "=== Finding recent CRIU logs ==="
LOGS=$(sudo find /run/containerd -name "criu-dump.log" -mmin -10 2>/dev/null)

if [ -z "$LOGS" ]; then
    echo "No recent logs found, checking all:"
    LOGS=$(sudo find /run/containerd -name "criu*.log" 2>/dev/null | head -5)
fi

for log in $LOGS; do
    echo ""
    echo "=== $log ==="
    sudo tail -40 "$log"
done

echo ""
echo "=== GRIT agent logs ==="
kubectl logs -l app=grit-agent --tail=30 2>/dev/null || echo "No grit-agent pod"

echo ""
echo "=== Recent job logs ==="
JOB=$(kubectl get jobs -o name 2>/dev/null | head -1)
if [ -n "$JOB" ]; then
    kubectl logs "$JOB" --tail=30 2>/dev/null
fi

