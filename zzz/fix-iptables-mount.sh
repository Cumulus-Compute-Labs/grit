#!/bin/bash
# Fix iptables by mounting host's /usr/sbin instead of using container's

echo "=== Updating ConfigMap to mount host iptables ==="

cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: grit-agent-config
  namespace: kube-system
data:
  host-path: /mnt/grit-agent
  grit-agent-template.yaml: |
    apiVersion: batch/v1
    kind: Job
    metadata:
      name: {{ .jobName }}
      namespace: {{ .namespace }}
      labels:
        grit.dev/helper: grit-agent
    spec:
      backoffLimit: 3
      template:
        spec:
          hostNetwork: true
          hostPID: true
          restartPolicy: Never
          volumes:
          - name: containerd-sock
            hostPath:
              path: /run/containerd/containerd.sock
              type: Socket
          - name: pod-logs
            hostPath:
              path: /var/log/pods
              type: Directory
          - name: host-criu
            hostPath:
              path: /usr/local/bin
              type: Directory
          - name: criu-plugins
            hostPath:
              path: /usr/lib/criu
              type: DirectoryOrCreate
          - name: lib64
            hostPath:
              path: /lib/x86_64-linux-gnu
              type: Directory
          - name: etc-criu
            hostPath:
              path: /etc/criu
              type: DirectoryOrCreate
          - name: cuda-bin
            hostPath:
              path: /usr/local/cuda/bin
              type: DirectoryOrCreate
          - name: host-sbin
            hostPath:
              path: /usr/sbin
              type: Directory
          - name: xtables
            hostPath:
              path: /usr/lib/x86_64-linux-gnu/xtables
              type: DirectoryOrCreate
          nodeName: {{ .nodeName }}
          tolerations:
          - operator: "Exists"
          containers:
          - name: grit-agent
            image: docker.io/library/grit-agent:gpu-fix
            command: ["/usr/local/bin/grit-agent"]
            args: ["--v=5", "--runtime-endpoint=/run/containerd/containerd.sock"]
            imagePullPolicy: Never
            securityContext:
              privileged: true
            env:
            - name: PATH
              value: "/usr/local/cuda/bin:/host-criu:/host-sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            - name: LD_LIBRARY_PATH
              value: "/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu"
            volumeMounts:
            - name: containerd-sock
              mountPath: /run/containerd/containerd.sock
            - name: pod-logs
              mountPath: /var/log/pods
            - name: host-criu
              mountPath: /host-criu
            - name: criu-plugins
              mountPath: /usr/lib/criu
            - name: lib64
              mountPath: /lib/x86_64-linux-gnu
            - name: etc-criu
              mountPath: /etc/criu
            - name: cuda-bin
              mountPath: /usr/local/cuda/bin
            - name: host-sbin
              mountPath: /host-sbin
            - name: xtables
              mountPath: /usr/lib/x86_64-linux-gnu/xtables
EOF

echo ""
echo "=== Restarting grit-manager ==="
kubectl rollout restart deployment/grit-manager -n kube-system
kubectl rollout status deployment/grit-manager -n kube-system --timeout=60s

echo ""
echo "✅ Done! Host iptables mounted at /host-sbin"
