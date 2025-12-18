#!/bin/bash
# Fix GRIT agent to have access to CRIU on the host

echo "=== Updating grit-agent-config to mount host CRIU ==="

# Mount CRIU to /host-criu (not /usr/local/bin which would overwrite the agent!)

cat <<'EOF' | kubectl apply -f -
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
EOF

echo ""
echo "=== Restarting grit-manager ==="
kubectl rollout restart deployment/grit-manager -n kube-system
kubectl rollout status deployment/grit-manager -n kube-system --timeout=60s

echo ""
echo "✅ ConfigMap updated with CRIU mounted at /host-criu"
