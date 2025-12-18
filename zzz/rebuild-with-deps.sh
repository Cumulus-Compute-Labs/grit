#!/bin/bash
# Rebuild with CRIU dependencies

cd /tmp/grit-build

# Update Dockerfile to install libbsd and criu dependencies
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

# Use image with required libraries
FROM --platform=$BUILDPLATFORM debian:bookworm-slim
WORKDIR /

# Install CRIU dependencies and utilities needed for mount fix
RUN apt-get update && apt-get install -y \
    libbsd0 \
    libnet1 \
    libnl-3-200 \
    libprotobuf-c1 \
    iptables \
    procps \
    gawk \
    util-linux \
    && rm -rf /var/lib/apt/lists/*

# Copy grit-agent binary
COPY --from=builder /workspace/_output/grit-agent /grit-agent
RUN mkdir -p /usr/local/bin && cp /grit-agent /usr/local/bin/grit-agent

ENTRYPOINT ["/grit-agent"]
DOCKERFILE

echo "Building with CRIU dependencies..."
sudo docker build --no-cache -t grit-agent:gpu-fix -f docker/grit-agent/Dockerfile . 2>&1 | tail -15
sudo ctr -n k8s.io images rm docker.io/library/grit-agent:gpu-fix 2>/dev/null || true
sudo docker save grit-agent:gpu-fix | sudo ctr -n k8s.io images import -
echo "Done!"
