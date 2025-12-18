#!/bin/bash
# Fix grit-agent to have cuda-checkpoint and iptables

set -e

echo "=== Step 1: Update Dockerfile to install iptables ==="

cd /tmp/grit-build

# Add iptables installation to Dockerfile
cat > docker/grit-agent/Dockerfile << 'DOCKERFILE'
# Build the binary
FROM --platform=$BUILDPLATFORM mcr.microsoft.com/oss/go/microsoft/golang:1.23 AS builder
ARG TARGETOS
ARG TARGETARCH

WORKDIR /workspace
COPY go.mod go.mod
COPY go.sum go.sum
ENV GOCACHE=/root/gocache
RUN \
    --mount=type=cache,target=${GOCACHE} \
    --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY cmd/ cmd/
COPY pkg/ pkg/
COPY Makefile Makefile

RUN --mount=type=cache,target=${GOCACHE} \
    --mount=type=cache,id=grit,sharing=locked,target=/go/pkg/mod \
    CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} GO111MODULE=on make bin/grit-agent

# Build a small image with required tools
FROM --platform=$BUILDPLATFORM mcr.microsoft.com/devcontainers/base:ubuntu
WORKDIR /

# Install iptables for CRIU network locking
RUN apt-get update && apt-get install -y \
    iptables \
    && rm -rf /var/lib/apt/lists/*

# Copy grit-agent binary
COPY --from=builder /workspace/_output/grit-agent /grit-agent
RUN mkdir -p /usr/local/bin && cp /grit-agent /usr/local/bin/grit-agent

# cuda-checkpoint will be mounted from host via volume mount
# PATH includes /usr/local/cuda/bin for cuda-checkpoint
ENV PATH="/usr/local/cuda/bin:/host-criu:${PATH}"

ENTRYPOINT ["/grit-agent"]
DOCKERFILE

echo "Updated Dockerfile:"
cat docker/grit-agent/Dockerfile

echo ""
echo "=== Step 2: Rebuild image ==="
sudo docker build --no-cache -t grit-agent:gpu-fix -f docker/grit-agent/Dockerfile . 2>&1 | tail -20

echo ""
echo "=== Step 3: Verify iptables is installed ==="
sudo docker run --rm --entrypoint sh grit-agent:gpu-fix -c "which iptables-restore && iptables --version"

echo ""
echo "=== Step 4: Import to containerd ==="
sudo ctr -n k8s.io images rm docker.io/library/grit-agent:gpu-fix 2>/dev/null || true
sudo docker save grit-agent:gpu-fix | sudo ctr -n k8s.io images import -

echo ""
echo "=== Step 5: Update ConfigMap to mount cuda-checkpoint ==="

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
              value: "/usr/local/cuda/bin:/host-criu:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
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
EOF

echo ""
echo "=== Step 6: Restart grit-manager ==="
kubectl rollout restart deployment/grit-manager -n kube-system
kubectl rollout status deployment/grit-manager -n kube-system --timeout=60s

echo ""
echo "✅ Done! Agent now has iptables and cuda-checkpoint in PATH"
