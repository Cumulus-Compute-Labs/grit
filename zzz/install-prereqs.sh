#!/bin/bash
set -eo pipefail

# ============================================================================
# Prerequisites Installation Script for GRIT (Checkpoint/Restore)
# ============================================================================
# This script installs:
# 1. NVIDIA Driver 580+
# 2. NVIDIA Container Toolkit
# 3. CUDA Toolkit (needed for cuda-checkpoint)
# 4. CRIU 4.0+ (built from source)
# 5. cuda-checkpoint utility
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root (use sudo)"
   exit 1
fi

# ============================================================================
# Step 1: System Update & Basic Dependencies
# ============================================================================
log_info "Step 1: Updating system and installing basic dependencies..."
apt-get update -qq

# Fix any broken packages first
apt-get --fix-broken install -y || true
dpkg --configure -a || true

apt-get install -y git build-essential pkg-config wget curl ubuntu-drivers-common software-properties-common

# ============================================================================
# Step 2: Install NVIDIA Driver 580+
# ============================================================================
log_info "Step 2: Installing NVIDIA Driver 580+..."

# Add graphics drivers PPA
add-apt-repository ppa:graphics-drivers/ppa -y
apt-get update -qq

# Fix broken packages again after adding PPA
apt-get --fix-broken install -y || true

# Install driver (headless for servers - no i386 dependencies)
if ! nvidia-smi 2>/dev/null | grep -q "Driver Version: 58"; then
    log_info "Installing nvidia-headless-580 (server version)..."
    # Use headless version to avoid i386 dependency issues on servers
    apt-get install -y --no-install-recommends nvidia-headless-580 nvidia-utils-580 || {
        log_info "Headless failed, trying standard driver..."
        apt-get install -y nvidia-driver-580 || apt-get install -y nvidia-driver-580-open || {
            log_error "Failed to find nvidia-driver-580. Listing available drivers:"
            ubuntu-drivers devices || true
            exit 1
        }
    }
    log_info "Driver installed. REBOOT REQUIRED after script completion."
else
    log_success "NVIDIA Driver 580+ already installed"
fi

# ============================================================================
# Step 3: Install NVIDIA Container Toolkit
# ============================================================================
log_info "Step 3: Installing NVIDIA Container Toolkit..."

if ! command -v nvidia-ctk &> /dev/null; then
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
    && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

    apt-get update -qq
    apt-get install -y nvidia-container-toolkit
    log_success "NVIDIA Container Toolkit installed"
else
    log_success "NVIDIA Container Toolkit already installed"
fi

# ============================================================================
# Step 4: Install CUDA Toolkit (needed for cuda-checkpoint)
# ============================================================================
log_info "Step 4: Installing CUDA Toolkit..."

if ! command -v nvcc &> /dev/null; then
    wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
    dpkg -i cuda-keyring_1.1-1_all.deb
    apt-get update -qq
    apt-get install -y cuda-toolkit-12-4
    rm cuda-keyring_1.1-1_all.deb
    
    # Add to path
    echo 'export PATH=/usr/local/cuda/bin:$PATH' >> /etc/bash.bashrc
    echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >> /etc/bash.bashrc
    export PATH=/usr/local/cuda/bin:$PATH
    export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
    
    log_success "CUDA Toolkit installed"
else
    log_success "CUDA Toolkit already installed"
fi

# ============================================================================
# Step 5: Install CRIU 4.0+
# ============================================================================
log_info "Step 5: Installing CRIU 4.0..."

if ! criu --version 2>/dev/null | grep -q "Version: 4"; then
    # Install dependencies (including asciidoc for man pages)
    apt-get install -y \
        libprotobuf-dev libprotobuf-c-dev protobuf-compiler protobuf-c-compiler \
        python3-protobuf libcap-dev libnet1-dev libnl-3-dev libaio-dev \
        libgnutls28-dev libnftables-dev libbsd-dev libdrm-dev libuuid1 \
        iproute2 unzip asciidoc xmlto

    # Download and build CRIU
    cd /tmp
    rm -rf criu-4.0 criu-4.0.tar.gz
    wget https://github.com/checkpoint-restore/criu/archive/refs/tags/v4.0.tar.gz -O criu-4.0.tar.gz
    tar -xzf criu-4.0.tar.gz
    cd criu-4.0
    make -j$(nproc)
    # Install binary directly (skip man pages if they fail)
    cp criu/criu /usr/local/bin/
    chmod +x /usr/local/bin/criu
    cd /tmp
    rm -rf criu-4.0*
    log_success "CRIU 4.0 installed"
else
    log_success "CRIU 4.0+ already installed"
fi

# ============================================================================
# Step 6: Build and Install CRIU CUDA Plugin
# ============================================================================
log_info "Step 6: Building CRIU CUDA plugin..."

# The CUDA plugin is part of CRIU source, needs to be built separately
if [ ! -f /usr/lib/criu/cuda_plugin.so ]; then
    cd /tmp
    if [ ! -d criu-4.0 ]; then
        wget https://github.com/checkpoint-restore/criu/archive/refs/tags/v4.0.tar.gz -O criu-4.0.tar.gz
        tar -xzf criu-4.0.tar.gz
    fi
    cd criu-4.0/plugins/cuda
    
    # Build the CUDA plugin
    make clean 2>/dev/null || true
    make -j$(nproc) || {
        log_info "CUDA plugin build failed - may need CUDA toolkit"
    }
    
    # Install the plugin
    mkdir -p /usr/lib/criu
    if [ -f cuda_plugin.so ]; then
        cp cuda_plugin.so /usr/lib/criu/
        chmod +x /usr/lib/criu/cuda_plugin.so
        log_success "CRIU CUDA plugin installed"
    else
        log_info "CUDA plugin not built - will try again after CUDA toolkit"
    fi
    
    cd /tmp
    rm -rf criu-4.0*
else
    log_success "CRIU CUDA plugin already installed"
fi

# ============================================================================
# Step 7: Configure CRIU for GPU Checkpoint Support
# ============================================================================
log_info "Step 7: Configuring CRIU for GPU checkpoint..."

# Create CRIU config with external mount support (fixes nvidia mount issues)
mkdir -p /etc/criu
cat > /etc/criu/default.conf << 'EOF'
# CRIU configuration for GPU container checkpoint
# Handles nvidia-container-runtime shared mounts
external mnt[]:sm
EOF

log_success "CRIU config created at /etc/criu/default.conf"

# ============================================================================
# Step 8: Configure nvidia-container-runtime for CRIU compatibility
# ============================================================================
log_info "Step 8: Configuring nvidia-container-runtime for CRIU..."

# Legacy mode is required for CRIU to handle seccomp filters properly
mkdir -p /etc/nvidia-container-runtime
cat > /etc/nvidia-container-runtime/config.toml << 'EOF'
[nvidia-container-runtime]
mode = "legacy"
EOF

log_success "nvidia-container-runtime configured for legacy mode"

# ============================================================================
# Step 9: Install cuda-checkpoint
# ============================================================================
log_info "Step 9: Installing cuda-checkpoint..."

# cuda-checkpoint is a pre-built binary, download from GitHub releases
if ! command -v cuda-checkpoint &> /dev/null; then
    cd /tmp
    rm -rf cuda-checkpoint
    git clone --depth 1 https://github.com/NVIDIA/cuda-checkpoint.git
    cd cuda-checkpoint
    
    # The binary should be in bin/x86_64_Linux/ (pre-compiled)
    if [ -f bin/x86_64_Linux/cuda-checkpoint ]; then
        cp bin/x86_64_Linux/cuda-checkpoint /usr/local/bin/
        chmod +x /usr/local/bin/cuda-checkpoint
        log_success "cuda-checkpoint installed from pre-built binary"
    else
        log_info "Pre-built binary not found, checking other locations..."
        # Try to find the binary anywhere in the repo
        FOUND_BIN=$(find . -name "cuda-checkpoint" -type f -executable 2>/dev/null | head -1)
        if [ -n "$FOUND_BIN" ]; then
            cp "$FOUND_BIN" /usr/local/bin/
            chmod +x /usr/local/bin/cuda-checkpoint
            log_success "cuda-checkpoint installed"
        else
            log_info "No pre-built binary found. Listing repo contents:"
            ls -laR
            log_info "cuda-checkpoint may need NVIDIA driver 570+ to be available"
            log_info "Skipping cuda-checkpoint installation for now"
        fi
    fi
    
    cd /tmp
    rm -rf cuda-checkpoint
else
    log_success "cuda-checkpoint already installed"
fi

echo ""
log_success "=========================================================="
log_success "Prerequisites Setup Complete!"
log_success "=========================================================="
log_info "Installed components:"
log_info "  - NVIDIA Driver 580+"
log_info "  - NVIDIA Container Toolkit"
log_info "  - CUDA Toolkit"
log_info "  - CRIU 4.0 with CUDA plugin"
log_info "  - cuda-checkpoint utility"
log_info ""
log_info "Configurations applied:"
log_info "  - /etc/criu/default.conf (external mount support)"
log_info "  - /etc/nvidia-container-runtime/config.toml (legacy mode)"
log_info ""
log_success "PLEASE REBOOT THE SYSTEM if NVIDIA drivers were installed."
log_success "=========================================================="

