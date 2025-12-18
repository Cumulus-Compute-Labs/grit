#!/bin/bash
sed -i 's|runtimeSocket: /run/k3s/containerd/containerd.sock|runtimeSocket: /run/containerd/containerd.sock|' /tmp/grit/charts/grit-manager/values.yaml
grep runtimeSocket /tmp/grit/charts/grit-manager/values.yaml
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
helm upgrade grit-manager /tmp/grit/charts/grit-manager -n kube-system
kubectl delete job grit-agent-gpu-counter-ckpt
sleep 10
kubectl get pods -A
kubectl get checkpoints
