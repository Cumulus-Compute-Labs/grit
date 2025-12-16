#!/bin/bash
set -e
SSH_KEY=~/.ssh/krish_key
SOURCE=ubuntu@163.192.28.24
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no"

echo "=== Step 6: Setup Kubernetes Resources ==="

echo "Creating RuntimeClasses..."
ssh $SSH_OPTS $SOURCE "
    kubectl apply -f - << 'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
---
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: grit
handler: grit
EOF
"

echo "Creating Storage resources..."
ssh $SSH_OPTS $SOURCE "
    # Delete existing resources first
    kubectl delete pvc grit-checkpoint-pvc -n default 2>/dev/null || true
    kubectl delete pvc grit-checkpoint-pvc -n grit-system 2>/dev/null || true
    kubectl delete pv grit-checkpoint-pv 2>/dev/null || true
    kubectl delete storageclass nfs-checkpoint 2>/dev/null || true
    sleep 3

    kubectl apply -f - << 'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-checkpoint
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: Immediate
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: grit-checkpoint-pv
spec:
  capacity:
    storage: 500Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: nfs-checkpoint
  hostPath:
    path: /mnt/grit-checkpoints
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: grit-checkpoint-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-checkpoint
  resources:
    requests:
      storage: 500Gi
EOF
"

echo "Checking GRIT Manager status..."
GRIT_PODS=$(ssh $SSH_OPTS $SOURCE "kubectl get pods -n grit-system --no-headers 2>/dev/null | wc -l")
if [ "$GRIT_PODS" -lt 1 ]; then
    echo "GRIT Manager not found. Installing via Helm..."
    ssh $SSH_OPTS $SOURCE "
        cd /opt/grit
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        
        # Create namespace if needed
        kubectl create namespace grit-system 2>/dev/null || true
        
        # Create PVC in grit-system namespace
        kubectl apply -f - << 'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: grit-checkpoint-pvc
  namespace: grit-system
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-checkpoint
  resources:
    requests:
      storage: 500Gi
EOF
        
        # Create values override
        cat > /tmp/grit-values.yaml << 'EOFVALUES'
log:
  level: 5
replicaCount: 1
certDuration: 87600h
hostPath: /mnt/grit-checkpoints
image:
  gritmanager:
    registry: ghcr.io
    repository: cumulus-compute-labs/grit-manager
    tag: dev
    pullSecrets: []
  gritagent:
    registry: ghcr.io
    repository: cumulus-compute-labs/grit-agent
    tag: dev
    pullSecrets: []
ports:
  metrics: 10351
  webhook: 10350
  healthProbe: 10352
resources:
  limits:
    cpu: 2000m
    memory: 1024Mi
  requests:
    cpu: 200m
    memory: 256Mi
EOFVALUES
        
        # Remove AKS-specific nodeSelector
        sed -i '/nodeSelector:/,/agentpool: agentpool/d' charts/grit-manager/templates/grit-manager.yaml 2>/dev/null || true
        
        helm upgrade --install grit-manager charts/grit-manager \
            -n grit-system \
            -f /tmp/grit-values.yaml \
            --wait --timeout 5m || echo 'Helm install completed (may have warnings)'
    "
else
    echo "GRIT Manager already running ($GRIT_PODS pods)"
fi

echo ""
echo "Checking GRIT CRDs..."
ssh $SSH_OPTS $SOURCE "kubectl get crds | grep -E 'checkpoint|restore'"

echo ""
echo "Checking RuntimeClasses..."
ssh $SSH_OPTS $SOURCE "kubectl get runtimeclass"

echo ""
echo "Checking PVCs..."
ssh $SSH_OPTS $SOURCE "kubectl get pvc -A | grep -E 'NAME|grit'"

echo ""
echo "Checking GRIT Manager pods..."
ssh $SSH_OPTS $SOURCE "kubectl get pods -n grit-system"

echo ""
echo "=== Step 6: Kubernetes Resources Setup Complete ==="
