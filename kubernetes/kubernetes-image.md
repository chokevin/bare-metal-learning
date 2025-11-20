# Building Custom Kubernetes Controller Images

## Overview

When deploying custom controllers in Kubernetes, you need to package them as container images. This guide covers best practices for building, optimizing, and deploying custom controller images.

## Image Building Strategies

### 1. Multi-Stage Builds (Recommended)

**Why:** Minimize final image size, separate build dependencies from runtime dependencies, improve security.

**Basic Go Controller Example:**
```dockerfile
# Stage 1: Build
FROM golang:1.21-alpine AS builder

WORKDIR /workspace

# Copy go mod files first (better layer caching)
COPY go.mod go.sum ./
RUN go mod download

# Copy source code
COPY cmd/ cmd/
COPY pkg/ pkg/
COPY api/ api/

# Build the controller
# CGO_ENABLED=0 for static binary (no libc dependency)
# -ldflags for smaller binary
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-w -s" \
    -a -o controller ./cmd/controller/main.go

# Stage 2: Runtime
FROM gcr.io/distroless/static:nonroot

WORKDIR /

# Copy only the binary from builder
COPY --from=builder /workspace/controller .

# Use nonroot user (UID 65532)
USER 65532:65532

ENTRYPOINT ["/controller"]
```

**Advantages:**
- Build stage: ~1GB (Go compiler, tools)
- Runtime stage: ~20MB (just static binary + distroless base)
- No unnecessary tools in production image
- Smaller attack surface

---

### 2. Distroless Base Images (Security-Focused)

**Why:** Minimal runtime environment with only essential libraries, no shell or package manager.

**Options:**

| Image | Use Case | Size | Contents |
|-------|----------|------|----------|
| `gcr.io/distroless/static:nonroot` | Static Go binaries | ~2MB | Minimal files, nonroot user |
| `gcr.io/distroless/base:nonroot` | Dynamic binaries (needs glibc) | ~20MB | glibc, CA certs, timezone data |
| `gcr.io/distroless/cc:nonroot` | C++ dependencies | ~25MB | libstdc++, libgcc |
| `gcr.io/distroless/python3:nonroot` | Python apps | ~50MB | Python runtime |

**Example with Kubernetes Client:**
```dockerfile
# Build stage
FROM golang:1.21-alpine AS builder

WORKDIR /workspace
COPY . .

RUN go mod download
RUN CGO_ENABLED=0 go build -ldflags="-w -s" -o controller ./cmd/controller

# Runtime - distroless with CA certificates for API calls
FROM gcr.io/distroless/static:nonroot

COPY --from=builder /workspace/controller /controller
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

USER 65532:65532

ENTRYPOINT ["/controller"]
```

---

### 3. Alpine-Based Images (Flexibility)

**Why:** Small base (~5MB), has shell for debugging, package manager for runtime deps.

**When to Use:**
- Need to debug inside container (`kubectl exec`)
- Require runtime package installation
- Need shell scripts alongside binary

```dockerfile
FROM golang:1.21-alpine AS builder

WORKDIR /workspace
COPY . .

RUN go mod download
RUN CGO_ENABLED=0 go build -ldflags="-w -s" -o controller ./cmd/controller

# Runtime
FROM alpine:3.19

# Install runtime dependencies
RUN apk add --no-cache ca-certificates tzdata

# Create nonroot user
RUN addgroup -g 65532 -S nonroot && \
    adduser -u 65532 -S nonroot -G nonroot

WORKDIR /

COPY --from=builder /workspace/controller .

USER nonroot:nonroot

ENTRYPOINT ["/controller"]
```

**Size Comparison:**
- Distroless: ~20MB
- Alpine: ~25MB
- Debian slim: ~80MB
- Ubuntu: ~80MB

---

### 4. Ubuntu-Based Images (Standard for Kubernetes Components)

**Why:** Standard base for official Kubernetes components, full package ecosystem, familiar tooling.

**When to Use:**
- Building Kubernetes system components (kubelet, kube-proxy)
- Need specific Ubuntu packages
- Corporate standard mandates Ubuntu
- Debugging with full Linux tools
- CGO dependencies requiring glibc

```dockerfile
# Build stage
FROM golang:1.21-bookworm AS builder

WORKDIR /workspace
COPY . .

RUN go mod download
RUN CGO_ENABLED=0 go build -ldflags="-w -s" -o controller ./cmd/controller

# Runtime - Ubuntu LTS
FROM ubuntu:22.04

# Update and install minimal dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

# Create nonroot user
RUN groupadd -g 65532 nonroot && \
    useradd -u 65532 -g nonroot -s /bin/bash -m nonroot

WORKDIR /

COPY --from=builder /workspace/controller .

USER nonroot:nonroot

ENTRYPOINT ["/controller"]
```

**Size Comparison:**
- Distroless: ~20MB
- Alpine: ~25MB
- Debian slim: ~80MB
- Ubuntu 22.04: ~77MB
- Ubuntu 22.04 (minimal): ~29MB (see below)

**Ubuntu Minimal (Smaller Base):**
```dockerfile
FROM ubuntu:22.04-minimal

# Minimal Ubuntu with only essential packages
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN groupadd -g 65532 nonroot && \
    useradd -u 65532 -g nonroot -s /bin/bash -m nonroot

COPY --from=builder /workspace/controller /controller

USER nonroot:nonroot

ENTRYPOINT ["/controller"]
```

**Ubuntu with Kubeadm Components:**

For controllers that need to interact with kubeadm or Kubernetes system components:

```dockerfile
# Build stage
FROM golang:1.21-bookworm AS builder

WORKDIR /workspace
COPY . .

RUN go mod download
RUN CGO_ENABLED=0 go build -ldflags="-w -s" -o controller ./cmd/controller

# Runtime - Ubuntu with Kubernetes tools
FROM ubuntu:22.04

# Install Kubernetes repository
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
    && rm -rf /var/lib/apt/lists/*

# Add Kubernetes apt repository
RUN curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | \
    gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

RUN echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /" | \
    tee /etc/apt/sources.list.d/kubernetes.list

# Install kubeadm, kubelet, kubectl (if needed by controller)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        kubelet=1.28.* \
        kubeadm=1.28.* \
        kubectl=1.28.* \
    && rm -rf /var/lib/apt/lists/*

# Create nonroot user
RUN groupadd -g 65532 nonroot && \
    useradd -u 65532 -g nonroot -s /bin/bash -m nonroot

WORKDIR /

COPY --from=builder /workspace/controller .

USER nonroot:nonroot

ENTRYPOINT ["/controller"]
```

**Size:** ~250MB (with kubeadm/kubelet/kubectl)

**Important Notes:**
- **Most controllers don't need kubeadm in the image** - they interact with Kubernetes API via client-go
- Only include kubeadm if your controller needs to:
  - Bootstrap clusters (cluster-api provider)
  - Manage control plane components
  - Execute kubeadm commands directly
- For standard controllers, use Ubuntu base without kubeadm

---

### 5. Operator SDK / Kubebuilder Pattern

**Why:** Standard tooling for Kubernetes controllers with built-in Dockerfiles.

**Kubebuilder-Generated Dockerfile:**
```dockerfile
# Build the manager binary
FROM golang:1.21 as builder
ARG TARGETOS
ARG TARGETARCH

WORKDIR /workspace

# Copy the Go Modules manifests
COPY go.mod go.mod
COPY go.sum go.sum

# Cache deps before building and copying source
RUN go mod download

# Copy the go source
COPY cmd/main.go cmd/main.go
COPY api/ api/
COPY internal/controller/ internal/controller/

# Build
RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} \
    go build -a -o manager cmd/main.go

# Use distroless as minimal base image
FROM gcr.io/distroless/static:nonroot

WORKDIR /

COPY --from=builder /workspace/manager .

USER 65532:65532

ENTRYPOINT ["/manager"]
```

**Features:**
- Multi-arch support (`TARGETOS`, `TARGETARCH`)
- Proper layer caching
- Distroless for security
- Follows Kubernetes conventions

---

## Standard Ubuntu Image Patterns for Kubernetes Controllers

### Pattern 1: Minimal Controller (Recommended)

**Use Case:** Standard Kubernetes controller that uses client-go to interact with API server.

```dockerfile
# Build stage
FROM golang:1.21-bookworm AS builder

WORKDIR /workspace

# Copy go mod files
COPY go.mod go.sum ./
RUN go mod download

# Copy source
COPY . .

# Build
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-w -s" \
    -a -o controller ./cmd/controller/main.go

# Runtime stage - Ubuntu minimal
FROM ubuntu:22.04

# Install CA certificates and timezone data
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

# Create nonroot user
RUN groupadd -g 65532 nonroot && \
    useradd -u 65532 -g nonroot -s /bin/bash -m nonroot

WORKDIR /app

COPY --from=builder /workspace/controller .

USER nonroot:nonroot

ENTRYPOINT ["/app/controller"]
```

**Size:** ~80-90MB  
**Best for:** 95% of custom controllers

---

### Pattern 2: Controller with kubectl CLI Access

**Use Case:** Controller needs to execute kubectl commands (not just API calls).

```dockerfile
# Build stage
FROM golang:1.21-bookworm AS builder

WORKDIR /workspace
COPY . .

RUN go mod download
RUN CGO_ENABLED=0 go build -ldflags="-w -s" -o controller ./cmd/controller

# Runtime stage - Ubuntu with kubectl
FROM ubuntu:22.04

# Install dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
    && rm -rf /var/lib/apt/lists/*

# Add Kubernetes apt repository
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | \
    gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

RUN echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /" | \
    tee /etc/apt/sources.list.d/kubernetes.list

# Install kubectl only (not kubeadm/kubelet)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        kubectl=1.28.* \
    && rm -rf /var/lib/apt/lists/*

# Create nonroot user
RUN groupadd -g 65532 nonroot && \
    useradd -u 65532 -g nonroot -s /bin/bash -m nonroot

WORKDIR /app

COPY --from=builder /workspace/controller .

USER nonroot:nonroot

ENTRYPOINT ["/app/controller"]
```

**Size:** ~120-140MB  
**Best for:** Controllers that shell out to kubectl (rare, prefer client-go)

---

### Pattern 3: Cluster API Provider (with kubeadm)

**Use Case:** Controller that provisions Kubernetes clusters using kubeadm.

```dockerfile
# Build stage
FROM golang:1.21-bookworm AS builder

WORKDIR /workspace
COPY . .

RUN go mod download
RUN CGO_ENABLED=0 go build -ldflags="-w -s" -o controller ./cmd/controller

# Runtime stage - Ubuntu with kubeadm tools
FROM ubuntu:22.04

# Install system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Add Kubernetes apt repository
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | \
    gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

RUN echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /" | \
    tee /etc/apt/sources.list.d/kubernetes.list

# Install Kubernetes tools
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        kubelet=1.28.* \
        kubeadm=1.28.* \
        kubectl=1.28.* \
    && rm -rf /var/lib/apt/lists/*

# Prevent automatic updates
RUN apt-mark hold kubelet kubeadm kubectl

# Create nonroot user (note: may need elevated permissions for cluster provisioning)
RUN groupadd -g 65532 nonroot && \
    useradd -u 65532 -g nonroot -s /bin/bash -m nonroot

WORKDIR /app

COPY --from=builder /workspace/controller .

# For cluster provisioning, you may need root or specific capabilities
# Adjust USER based on your security requirements
USER nonroot:nonroot

ENTRYPOINT ["/app/controller"]
```

**Size:** ~250-300MB  
**Best for:** Cluster API providers, cluster bootstrapping controllers

**Security Note:** Controllers that execute kubeadm may need elevated permissions. Use Kubernetes SecurityContext to grant specific capabilities instead of running as root:

```yaml
securityContext:
  capabilities:
    add:
    - NET_ADMIN  # If needed for network setup
    - SYS_ADMIN  # If needed for cluster operations
  runAsUser: 65532
  runAsGroup: 65532
```

---

### Pattern 4: DaemonSet Node Controller

**Use Case:** Controller runs as DaemonSet with host access (CNI plugins, device plugins).

```dockerfile
# Build stage
FROM golang:1.21-bookworm AS builder

WORKDIR /workspace
COPY . .

RUN go mod download
RUN CGO_ENABLED=0 go build -ldflags="-w -s" -o controller ./cmd/controller

# Runtime stage - Ubuntu with system tools
FROM ubuntu:22.04

# Install system utilities for node operations
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        iptables \
        iproute2 \
        ipset \
        kmod \
        util-linux \
    && rm -rf /var/lib/apt/lists/*

# Create nonroot user (may run as root for host access)
RUN groupadd -g 65532 nonroot && \
    useradd -u 65532 -g nonroot -s /bin/bash -m nonroot

WORKDIR /app

COPY --from=builder /workspace/controller .

# DaemonSets often need root for host operations
# USER nonroot:nonroot  # Uncomment if possible

ENTRYPOINT ["/app/controller"]
```

**Size:** ~150-180MB  
**Best for:** CNI plugins, CSI drivers, device plugins

**Deployment:**
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-controller
spec:
  template:
    spec:
      hostNetwork: true  # Access host network
      hostPID: true      # Access host processes
      containers:
      - name: controller
        image: myregistry/node-controller:v1.0.0
        securityContext:
          privileged: true  # Often required for node operations
        volumeMounts:
        - name: host-root
          mountPath: /host
          readOnly: true
        - name: run
          mountPath: /run
      volumes:
      - name: host-root
        hostPath:
          path: /
      - name: run
        hostPath:
          path: /run
```

---

### Pattern 5: Controller with systemd/init Integration

**Use Case:** Controller needs to manage systemd services on nodes.

```dockerfile
# Build stage
FROM golang:1.21-bookworm AS builder

WORKDIR /workspace
COPY . .

RUN go mod download
RUN CGO_ENABLED=1 go build -ldflags="-w -s" -o controller ./cmd/controller

# Runtime stage - Ubuntu with systemd
FROM ubuntu:22.04

# Install systemd and dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        systemd \
        dbus \
    && rm -rf /var/lib/apt/lists/*

# Create nonroot user
RUN groupadd -g 65532 nonroot && \
    useradd -u 65532 -g nonroot -s /bin/bash -m nonroot

WORKDIR /app

COPY --from=builder /workspace/controller .

# May need root to interact with systemd
USER nonroot:nonroot

ENTRYPOINT ["/app/controller"]
```

**Size:** ~200-250MB  
**Best for:** Node lifecycle controllers, service management

---

## Comparison: When to Use Each Base Image

| Base Image | Size | Use Case | Security | Debugging |
|------------|------|----------|----------|-----------|
| **Distroless** | ~20MB | Production controllers | ★★★★★ | ★☆☆☆☆ |
| **Alpine** | ~25MB | Dev/test, need shell | ★★★★☆ | ★★★★☆ |
| **Ubuntu Minimal** | ~30MB | Small footprint + packages | ★★★★☆ | ★★★☆☆ |
| **Ubuntu 22.04** | ~80MB | Standard controllers | ★★★☆☆ | ★★★★★ |
| **Ubuntu + kubectl** | ~140MB | CLI operations | ★★★☆☆ | ★★★★★ |
| **Ubuntu + kubeadm** | ~300MB | Cluster provisioning | ★★☆☆☆ | ★★★★★ |

### Decision Tree

```
Do you need kubeadm?
├─ YES: Are you building a Cluster API provider?
│   ├─ YES → Pattern 3 (Ubuntu + kubeadm)
│   └─ NO: Do you need to execute kubectl commands?
│       ├─ YES → Pattern 2 (Ubuntu + kubectl)
│       └─ NO → Pattern 1 (Ubuntu minimal)
│
└─ NO: Is this a node-level controller (DaemonSet)?
    ├─ YES → Pattern 4 (Ubuntu + system tools)
    └─ NO: Do you need maximum security?
        ├─ YES → Use distroless (from earlier sections)
        └─ NO → Pattern 1 (Ubuntu minimal)
```

---

## Ubuntu-Specific Best Practices

### 1. Keep APT Cache Clean

```dockerfile
# ❌ BAD: Leaves cache, increases image size by 100MB+
RUN apt-get update
RUN apt-get install -y ca-certificates
# Image size: +100MB unnecessary cache

# ✅ GOOD: Clean up in same layer
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*
# Image size: minimal
```

### 2. Pin Kubernetes Versions

```dockerfile
# ❌ BAD: Gets latest version (breaks compatibility)
RUN apt-get install -y kubectl

# ✅ GOOD: Pin to specific minor version
RUN apt-get install -y kubectl=1.28.*

# ✅ BETTER: Pin to exact version for reproducibility
RUN apt-get install -y kubectl=1.28.4-1.1

# Prevent automatic updates
RUN apt-mark hold kubectl
```

### 3. Use --no-install-recommends

```dockerfile
# ❌ BAD: Installs 200MB+ of recommended packages
RUN apt-get install -y kubectl
# Pulls in man pages, docs, optional tools

# ✅ GOOD: Only install required packages
RUN apt-get install -y --no-install-recommends kubectl
# Saves 50-100MB
```

### 4. Multi-Stage with Ubuntu

```dockerfile
# Build with full Debian (more packages available)
FROM golang:1.21-bookworm AS builder
WORKDIR /workspace
COPY . .
RUN go mod download
RUN go build -o controller ./cmd

# Runtime with Ubuntu (corporate standard)
FROM ubuntu:22.04
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*
COPY --from=builder /workspace/controller /controller
ENTRYPOINT ["/controller"]
```

### 5. Health Checks in Ubuntu Images

```dockerfile
FROM ubuntu:22.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /workspace/controller /controller

# Health check endpoint
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/healthz || exit 1

ENTRYPOINT ["/controller"]
```

---

## Example: Production-Ready Ubuntu Controller

**Complete example with all best practices:**

```dockerfile
# syntax=docker/dockerfile:1

# Build stage
FROM golang:1.21-bookworm AS builder

ARG VERSION=dev
ARG GIT_COMMIT=unknown
ARG BUILD_TIME

WORKDIR /workspace

# Copy go mod files for caching
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

# Copy source
COPY cmd/ cmd/
COPY pkg/ pkg/
COPY api/ api/

# Build
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-w -s \
              -X main.Version=${VERSION} \
              -X main.GitCommit=${GIT_COMMIT} \
              -X main.BuildTime=${BUILD_TIME}" \
    -a -o controller ./cmd/controller/main.go

# Runtime stage - Ubuntu LTS
FROM ubuntu:22.04

# Install runtime dependencies in single layer
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Create nonroot user
RUN groupadd -g 65532 nonroot && \
    useradd -u 65532 -g nonroot -s /bin/bash -m -d /home/nonroot nonroot

# Create app directory with proper permissions
RUN mkdir -p /app && chown nonroot:nonroot /app

WORKDIR /app

# Copy binary from builder
COPY --from=builder --chown=nonroot:nonroot /workspace/controller .

# Switch to nonroot user
USER nonroot:nonroot

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/app/controller", "healthz"]

# Expose metrics port (if applicable)
EXPOSE 8080 8443

# Labels for metadata
LABEL org.opencontainers.image.title="My Kubernetes Controller"
LABEL org.opencontainers.image.description="Custom controller for managing resources"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.vendor="My Company"

ENTRYPOINT ["/app/controller"]
CMD ["--help"]
```

**Build command:**
```bash
docker build \
  --build-arg VERSION=v1.2.3 \
  --build-arg GIT_COMMIT=$(git rev-parse HEAD) \
  --build-arg BUILD_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ") \
  -t myregistry/my-controller:v1.2.3 \
  .
```

**Size:** ~85MB  
**Security:** Non-root, minimal packages  
**Performance:** BuildKit caching enabled  
**Compliance:** Corporate Ubuntu standard

---

## Real-World Architecture: Management Cluster + DPU Node Controllers

### Key Question: Where Do CRs Live?

**Answer: It depends on your architecture. Three options:**

#### **Option 1: Single Cluster (Simplest)**
Management controllers and DPU agents run in the **same cluster**. CRs live in the same API server.

```
┌─────────────────────────────────────────────────────────────┐
│                    Single Kubernetes Cluster                 │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Control Plane Nodes (API Server + etcd)             │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Management Controller (Deployment)                   │  │
│  │ - Watches NetworkPolicy                              │  │
│  │ - Creates DPURule CRs → Same API Server             │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Customer Node 1 (with DPU)                           │  │
│  │ ┌──────────────────────────────────────────────────┐ │  │
│  │ │ DPU Agent (DaemonSet)                            │ │  │
│  │ │ - Watches DPURule CRs ← Same API Server         │ │  │
│  │ │ - Programs hardware                              │ │  │
│  │ └──────────────────────────────────────────────────┘ │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Customer Node 2 (with DPU)                           │  │
│  │ ┌──────────────────────────────────────────────────┐ │  │
│  │ │ DPU Agent (DaemonSet)                            │ │  │
│  │ │ - Watches DPURule CRs ← Same API Server         │ │  │
│  │ └──────────────────────────────────────────────────┘ │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

**Pros:** Simple, single source of truth, no cross-cluster auth  
**Cons:** Customer nodes need API server access, tighter coupling  
**Best for:** Single tenant, enterprise internal use

---

#### **Option 2: Hub-Spoke (Management + Customer Clusters)**
Management controllers run in **hub cluster**, write CRs to **customer spoke clusters**.

```
┌─────────────────────────────────────────────────────────────┐
│              Management Cluster (Hub)                        │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Management Controller (Deployment)                   │  │
│  │ - Watches: Local NetworkPolicy                       │  │
│  │ - Writes: DPURule CRs to Customer Clusters          │  │
│  │                                                       │  │
│  │ Multi-cluster client-go:                            │  │
│  │ - customer-1 kubeconfig → 192.168.1.10:6443        │  │
│  │ - customer-2 kubeconfig → 192.168.2.10:6443        │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                  │                            │
                  │ API calls                  │ API calls
                  │ (kubeconfig 1)             │ (kubeconfig 2)
                  ▼                            ▼
┌────────────────────────────┐   ┌────────────────────────────┐
│   Customer Cluster 1       │   │   Customer Cluster 2       │
│                            │   │                            │
│  ┌──────────────────────┐ │   │  ┌──────────────────────┐ │
│  │ API Server + etcd    │ │   │  │ API Server + etcd    │ │
│  │ (stores DPURule CRs)│ │   │  │ (stores DPURule CRs)│ │
│  └──────────────────────┘ │   │  └──────────────────────┘ │
│                            │   │                            │
│  ┌──────────────────────┐ │   │  ┌──────────────────────┐ │
│  │ Node 1 (DPU)         │ │   │  │ Node 1 (DPU)         │ │
│  │ ┌──────────────────┐ │ │   │  │ ┌──────────────────┐ │ │
│  │ │ DPU Agent        │ │ │   │  │ │ DPU Agent        │ │ │
│  │ │ Watches local CRs│ │ │   │  │ │ Watches local CRs│ │ │
│  │ └──────────────────┘ │ │   │  │ └──────────────────┘ │ │
│  └──────────────────────┘ │   │  └──────────────────────┘ │
└────────────────────────────┘   └────────────────────────────┘
```

**Pros:** Strong tenant isolation, customers don't need hub access  
**Cons:** Complex auth (hub needs customer kubeconfigs), network connectivity  
**Best for:** Multi-tenant SaaS, managed service provider

---

#### **Option 3: Local Control Plane (Most Isolated)**
Each customer cluster has **its own management controller** watching local resources.

```
┌────────────────────────────────────────────────────────────┐
│              Customer Cluster 1 (Self-Contained)           │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐ │
│  │ Management Controller (Deployment)                   │ │
│  │ - Watches: NetworkPolicy (same cluster)             │ │
│  │ - Creates: DPURule CRs (same cluster)               │ │
│  └──────────────────────────────────────────────────────┘ │
│                          ↓ (same API server)               │
│  ┌──────────────────────────────────────────────────────┐ │
│  │ DPU Agent (DaemonSet on node-1)                      │ │
│  │ - Watches: DPURule CRs (same cluster)                │ │
│  │ - Programs: Hardware                                  │ │
│  └──────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────┐
│              Customer Cluster 2 (Self-Contained)           │
│  (Same setup, completely independent)                      │
└────────────────────────────────────────────────────────────┘
```

**Pros:** Maximum isolation, no cross-cluster dependencies  
**Cons:** Controller deployed per cluster (more ops overhead)  
**Best for:** Customer-managed clusters, edge deployments

---

### Architecture Overview (Option 1: Single Cluster)

```
┌─────────────────────────────────────────────────────────────┐
│                    Single Kubernetes Cluster                 │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Control Plane (kubeadm-based)                         │ │
│  │  - API Server, etcd, Controller Manager, Scheduler     │ │
│  │  - Stores: NetworkPolicy, DPURule CRDs                 │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  CRD Controllers (Deployment)                          │ │
│  │  ┌─────────────────┐  ┌──────────────────┐           │ │
│  │  │ Network Policy  │  │ DPU Resource     │           │ │
│  │  │ Controller      │  │ Controller       │           │ │
│  │  │                 │  │                  │           │ │
│  │  │ Watches:        │  │ Watches:         │           │ │
│  │  │ - NetworkPolicy │  │ - DPUConfig      │           │ │
│  │  │ - Pod           │  │ - DPUNode        │           │ │
│  │  │                 │  │                  │           │ │
│  │  │ Creates:        │  │ Creates:         │           │ │
│  │  │ - DPURule CRs   │  │ - DPURuleConfig  │           │ │
│  │  │   (same cluster)│  │   (same cluster) │           │ │
│  │  └─────────────────┘  └──────────────────┘           │ │
│  └────────────────────────────────────────────────────────┘ │
│                            │                                 │
│                            │ Same API server                 │
│                            │ (no cross-cluster calls)        │
│                            ▼                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Customer Node 1 (BlueField-2 DPU)                  │   │
│  │  ┌────────────────────────────────────────────────┐ │   │
│  │  │ DPU Agent Controller (DaemonSet)               │ │   │
│  │  │                                                 │ │   │
│  │  │ Watches: DPURule CRs (label: node=node-1)     │ │   │
│  │  │          ↑ Same API server                     │ │   │
│  │  │                                                 │ │   │
│  │  │ Actions:                                       │ │   │
│  │  │ - Programs OVS flow tables                    │ │   │
│  │  │ - Configures DOCA Flow API                    │ │   │
│  │  │ - Updates hardware flow tables                │ │   │
│  │  │ - Reports status back to CR                   │ │   │
│  │  └────────────────────────────────────────────────┘ │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Customer Node 2 (BlueField-3 DPU)                  │   │
│  │  ┌────────────────────────────────────────────────┐ │   │
│  │  │ DPU Agent Controller (DaemonSet)               │ │   │
│  │  │ - Watches same API server                      │ │   │
│  │  │ - Different node label filter                  │ │   │
│  │  └────────────────────────────────────────────────┘ │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## Implementation Details by Architecture

### Option 1: Single Cluster (Simple)

**Controller Code:** No changes needed from examples above - uses default in-cluster config.

```go
// Uses in-cluster service account
mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
    Scheme: scheme,
})
```

---

### Option 2: Hub-Spoke Multi-Cluster (Complex)

**Use Case:** Management cluster writes DPURule CRs to multiple customer clusters.

#### Management Controller with Multi-Cluster Support

```go
// cmd/network-policy-controller/main.go
package main

import (
    "context"
    "flag"
    
    "k8s.io/client-go/kubernetes"
    "k8s.io/client-go/tools/clientcmd"
    ctrl "sigs.k8s.io/controller-runtime"
    
    "github.com/mycompany/dpu-operator/pkg/multicluster"
)

func main() {
    var customerClustersConfig string
    
    flag.StringVar(&customerClustersConfig, "customer-clusters", "/config/clusters.yaml",
        "Path to customer clusters configuration")
    flag.Parse()
    
    // Setup manager for hub cluster (watch NetworkPolicy)
    hubMgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
        Scheme: scheme,
    })
    if err != nil {
        setupLog.Error(err, "unable to start hub manager")
        os.Exit(1)
    }
    
    // Load customer cluster configurations
    customerClients, err := multicluster.NewCustomerClients(customerClustersConfig)
    if err != nil {
        setupLog.Error(err, "unable to load customer cluster configs")
        os.Exit(1)
    }
    
    // Setup NetworkPolicy controller with multi-cluster support
    if err = (&controllers.NetworkPolicyReconciler{
        HubClient:       hubMgr.GetClient(),
        CustomerClients: customerClients,
        Scheme:          hubMgr.GetScheme(),
    }).SetupWithManager(hubMgr); err != nil {
        setupLog.Error(err, "unable to create controller")
        os.Exit(1)
    }
    
    setupLog.Info("starting multi-cluster manager")
    if err := hubMgr.Start(ctrl.SetupSignalHandler()); err != nil {
        setupLog.Error(err, "problem running manager")
        os.Exit(1)
    }
}
```

```go
// pkg/multicluster/client.go
package multicluster

import (
    "fmt"
    "os"
    
    "k8s.io/client-go/kubernetes"
    "k8s.io/client-go/tools/clientcmd"
    "sigs.k8s.io/controller-runtime/pkg/client"
    "sigs.k8s.io/yaml"
)

type CustomerClients struct {
    Clients map[string]client.Client // clusterName -> client
}

type ClusterConfig struct {
    Clusters []struct {
        Name       string `json:"name"`
        Kubeconfig string `json:"kubeconfig"` // Path to kubeconfig
    } `json:"clusters"`
}

func NewCustomerClients(configPath string) (*CustomerClients, error) {
    // Read clusters config
    data, err := os.ReadFile(configPath)
    if err != nil {
        return nil, fmt.Errorf("failed to read config: %w", err)
    }
    
    var config ClusterConfig
    if err := yaml.Unmarshal(data, &config); err != nil {
        return nil, fmt.Errorf("failed to parse config: %w", err)
    }
    
    clients := make(map[string]client.Client)
    
    for _, cluster := range config.Clusters {
        // Load kubeconfig for customer cluster
        cfg, err := clientcmd.BuildConfigFromFlags("", cluster.Kubeconfig)
        if err != nil {
            return nil, fmt.Errorf("failed to load kubeconfig for %s: %w", cluster.Name, err)
        }
        
        // Create client for customer cluster
        c, err := client.New(cfg, client.Options{Scheme: scheme})
        if err != nil {
            return nil, fmt.Errorf("failed to create client for %s: %w", cluster.Name, err)
        }
        
        clients[cluster.Name] = c
    }
    
    return &CustomerClients{Clients: clients}, nil
}

func (cc *CustomerClients) GetClient(clusterName string) (client.Client, error) {
    c, ok := cc.Clients[clusterName]
    if !ok {
        return nil, fmt.Errorf("cluster %s not found", clusterName)
    }
    return c, nil
}
```

```go
// controllers/networkpolicy_controller.go (multi-cluster version)
package controllers

import (
    "context"
    "fmt"
    
    networkingv1 "k8s.io/api/networking/v1"
    ctrl "sigs.k8s.io/controller-runtime"
    "sigs.k8s.io/controller-runtime/pkg/client"
    
    dpuv1 "github.com/mycompany/dpu-operator/api/v1"
    "github.com/mycompany/dpu-operator/pkg/multicluster"
)

type NetworkPolicyReconciler struct {
    HubClient       client.Client  // Hub cluster (watches NetworkPolicy)
    CustomerClients *multicluster.CustomerClients  // Customer clusters (writes DPURule)
    Scheme          *runtime.Scheme
}

func (r *NetworkPolicyReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    log := ctrl.LoggerFrom(ctx)
    
    // Fetch NetworkPolicy from hub cluster
    var netpol networkingv1.NetworkPolicy
    if err := r.HubClient.Get(ctx, req.NamespacedName, &netpol); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }
    
    // Get target cluster from annotation
    clusterName := netpol.Annotations["dpu.io/target-cluster"]
    if clusterName == "" {
        log.Info("NetworkPolicy missing target-cluster annotation, skipping")
        return ctrl.Result{}, nil
    }
    
    // Get customer cluster client
    customerClient, err := r.CustomerClients.GetClient(clusterName)
    if err != nil {
        log.Error(err, "failed to get customer cluster client", "cluster", clusterName)
        return ctrl.Result{}, err
    }
    
    // Get all pods matching this policy (from hub cluster)
    pods := &corev1.PodList{}
    if err := r.HubClient.List(ctx, pods,
        client.InNamespace(netpol.Namespace),
        client.MatchingLabels(netpol.Spec.PodSelector.MatchLabels),
    ); err != nil {
        return ctrl.Result{}, err
    }
    
    // For each pod, create DPURule in customer cluster
    for _, pod := range pods.Items {
        nodeName := pod.Spec.NodeName
        
        dpuRule := &dpuv1.DPURule{
            ObjectMeta: metav1.ObjectMeta{
                Name:      fmt.Sprintf("%s-%s", netpol.Name, nodeName),
                Namespace: "dpu-system",
                Labels: map[string]string{
                    "node": nodeName,
                },
            },
            Spec: dpuv1.DPURuleSpec{
                NodeName: nodeName,
                Rules:    convertNetworkPolicyToFlowRules(&netpol, &pod),
            },
        }
        
        // Write to customer cluster (not hub cluster!)
        if err := customerClient.Create(ctx, dpuRule); err != nil {
            if !errors.IsAlreadyExists(err) {
                return ctrl.Result{}, err
            }
            if err := customerClient.Update(ctx, dpuRule); err != nil {
                return ctrl.Result{}, err
            }
        }
        
        log.Info("Created DPURule in customer cluster",
            "cluster", clusterName,
            "rule", dpuRule.Name,
            "node", nodeName)
    }
    
    return ctrl.Result{}, nil
}

func (r *NetworkPolicyReconciler) SetupWithManager(mgr ctrl.Manager) error {
    // Watch NetworkPolicy in hub cluster
    return ctrl.NewControllerManagedBy(mgr).
        For(&networkingv1.NetworkPolicy{}).
        Complete(r)
}
```

#### Configuration Files

```yaml
# config/clusters.yaml
# Mounted as ConfigMap or Secret
clusters:
- name: customer-1
  kubeconfig: /config/customer-1.kubeconfig

- name: customer-2
  kubeconfig: /config/customer-2.kubeconfig
```

```yaml
# deploy/network-policy-controller-multicluster.yaml
apiVersion: v1
kind: Secret
metadata:
  name: customer-kubeconfigs
  namespace: dpu-system
type: Opaque
data:
  # Base64-encoded kubeconfig files
  customer-1.kubeconfig: <base64-kubeconfig>
  customer-2.kubeconfig: <base64-kubeconfig>

---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-config
  namespace: dpu-system
data:
  clusters.yaml: |
    clusters:
    - name: customer-1
      kubeconfig: /config/kubeconfigs/customer-1.kubeconfig
    - name: customer-2
      kubeconfig: /config/kubeconfigs/customer-2.kubeconfig

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: network-policy-controller
  namespace: dpu-system
spec:
  replicas: 2
  selector:
    matchLabels:
      app: network-policy-controller
  template:
    metadata:
      labels:
        app: network-policy-controller
    spec:
      serviceAccountName: network-policy-controller
      
      containers:
      - name: controller
        image: myregistry/network-policy-controller:v1.0.0
        
        args:
        - --leader-elect
        - --customer-clusters=/config/clusters.yaml
        
        volumeMounts:
        - name: cluster-config
          mountPath: /config
          readOnly: true
        - name: customer-kubeconfigs
          mountPath: /config/kubeconfigs
          readOnly: true
      
      volumes:
      - name: cluster-config
        configMap:
          name: cluster-config
      - name: customer-kubeconfigs
        secret:
          secretName: customer-kubeconfigs
```

#### NetworkPolicy with Target Annotation

```yaml
# User creates this in hub cluster
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-http
  namespace: default
  annotations:
    dpu.io/target-cluster: customer-1  # ← Write DPURule to customer-1 cluster
spec:
  podSelector:
    matchLabels:
      app: web
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 80
```

**Flow:**
1. User creates NetworkPolicy in **hub cluster** with annotation
2. Hub controller watches NetworkPolicy in hub cluster
3. Hub controller writes DPURule CRs to **customer-1 cluster** (using kubeconfig)
4. DPU agents in customer-1 cluster watch their local API server
5. DPU agents see new DPURule CRs and program hardware

---

### How Hub-Spoke Actually Connects to Customer Clusters

There are **4 common approaches** for hub clusters to write CRs to spoke (customer) clusters:

#### **Approach 1: Direct API Server Access with Kubeconfig (Most Common)**

**How it works:** Hub controller has kubeconfig files for each customer cluster mounted as secrets.

**Advantages:**
- ✅ Simple and direct
- ✅ Works with any Kubernetes cluster
- ✅ No additional infrastructure

**Disadvantages:**
- ❌ Hub needs network access to customer API servers
- ❌ Managing N kubeconfig credentials
- ❌ Customer API servers must be accessible from hub
- ❌ Firewall rules needed (hub → customer:6443)

**Network Requirements:**
```
Hub Cluster (10.1.0.0/16)
    ↓
    Internet/VPN/Private Link
    ↓
Customer-1 API Server (192.168.1.10:6443)
Customer-2 API Server (192.168.2.10:6443)
```

**Implementation:** (Already shown above in Option 2 code)

**Security Setup:**
```yaml
# 1. Create ServiceAccount in customer cluster
apiVersion: v1
kind: ServiceAccount
metadata:
  name: hub-controller
  namespace: dpu-system

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: hub-controller
rules:
- apiGroups: ["dpu.io"]
  resources: ["dpurules"]
  verbs: ["create", "update", "patch", "delete", "get", "list", "watch"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: hub-controller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: hub-controller
subjects:
- kind: ServiceAccount
  name: hub-controller
  namespace: dpu-system

---
# 2. Create token for ServiceAccount
apiVersion: v1
kind: Secret
metadata:
  name: hub-controller-token
  namespace: dpu-system
  annotations:
    kubernetes.io/service-account.name: hub-controller
type: kubernetes.io/service-account-token
```

**Generate Kubeconfig:**
```bash
#!/bin/bash
# generate-kubeconfig.sh

CLUSTER_NAME="customer-1"
API_SERVER="https://192.168.1.10:6443"
NAMESPACE="dpu-system"
SA_NAME="hub-controller"
SECRET_NAME="hub-controller-token"

# Get token and CA cert from customer cluster
TOKEN=$(kubectl --context=$CLUSTER_NAME get secret $SECRET_NAME -n $NAMESPACE -o jsonpath='{.data.token}' | base64 -d)
CA_CERT=$(kubectl --context=$CLUSTER_NAME get secret $SECRET_NAME -n $NAMESPACE -o jsonpath='{.data.ca\.crt}')

# Generate kubeconfig
cat > customer-1.kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: $CA_CERT
    server: $API_SERVER
  name: $CLUSTER_NAME
contexts:
- context:
    cluster: $CLUSTER_NAME
    user: hub-controller
  name: hub-controller@$CLUSTER_NAME
current-context: hub-controller@$CLUSTER_NAME
users:
- name: hub-controller
  user:
    token: $TOKEN
EOF

# Create secret in hub cluster
kubectl --context=hub create secret generic customer-kubeconfigs \
  -n dpu-system \
  --from-file=customer-1.kubeconfig=customer-1.kubeconfig
```

---

#### **Approach 2: Kubernetes Multi-Cluster Services (MCS API)**

**How it works:** Use Kubernetes Multi-Cluster Services API for service discovery and connectivity.

**Advantages:**
- ✅ Standard Kubernetes API
- ✅ Built-in service discovery
- ✅ Works with service meshes (Istio, Linkerd)

**Disadvantages:**
- ❌ Requires MCS API support (not all clusters have it)
- ❌ Complex setup
- ❌ Limited adoption

**Architecture:**
```
Hub Cluster
    ↓ (MCS API)
Service Import/Export
    ↓
Customer Cluster API Server (discovered via MCS)
```

**Not commonly used for this pattern** - better for service-to-service communication.

---

#### **Approach 3: Cluster API Provider (Declarative Cluster Management)**

**How it works:** Use Cluster API to provision and manage customer clusters. Hub has native access through Cluster API.

**Advantages:**
- ✅ Unified cluster lifecycle management
- ✅ Hub provisions customer clusters
- ✅ Built-in credential management
- ✅ Industry standard for multi-cluster

**Disadvantages:**
- ❌ Only works if hub provisions clusters
- ❌ Customer clusters must be Cluster API-managed
- ❌ Heavy infrastructure requirement

**Architecture:**
```
Hub Cluster
  ├─ Cluster API Controllers
  ├─ Cluster CRD: customer-1
  │   ├─ Kubeconfig stored in Secret
  │   └─ Hub has admin access
  └─ Cluster CRD: customer-2
      ├─ Kubeconfig stored in Secret
      └─ Hub has admin access
```

**Implementation:**
```go
// pkg/multicluster/clusterapi.go
package multicluster

import (
    "context"
    "fmt"
    
    clusterv1 "sigs.k8s.io/cluster-api/api/v1beta1"
    "k8s.io/client-go/tools/clientcmd"
    "sigs.k8s.io/controller-runtime/pkg/client"
)

type ClusterAPIClients struct {
    HubClient client.Client
    clients   map[string]client.Client
}

func NewClusterAPIClients(hubClient client.Client) (*ClusterAPIClients, error) {
    return &ClusterAPIClients{
        HubClient: hubClient,
        clients:   make(map[string]client.Client),
    }, nil
}

func (c *ClusterAPIClients) GetClient(ctx context.Context, clusterName string) (client.Client, error) {
    // Check cache
    if client, ok := c.clients[clusterName]; ok {
        return client, nil
    }
    
    // Fetch Cluster CR from hub
    var cluster clusterv1.Cluster
    if err := c.HubClient.Get(ctx, client.ObjectKey{
        Name:      clusterName,
        Namespace: "default",
    }, &cluster); err != nil {
        return nil, fmt.Errorf("cluster %s not found: %w", clusterName, err)
    }
    
    // Get kubeconfig from secret (automatically created by Cluster API)
    secretName := fmt.Sprintf("%s-kubeconfig", clusterName)
    var secret corev1.Secret
    if err := c.HubClient.Get(ctx, client.ObjectKey{
        Name:      secretName,
        Namespace: cluster.Namespace,
    }, &secret); err != nil {
        return nil, fmt.Errorf("kubeconfig secret not found: %w", err)
    }
    
    // Parse kubeconfig
    kubeconfigData := secret.Data["value"]
    config, err := clientcmd.RESTConfigFromKubeConfig(kubeconfigData)
    if err != nil {
        return nil, fmt.Errorf("failed to parse kubeconfig: %w", err)
    }
    
    // Create client
    customerClient, err := client.New(config, client.Options{Scheme: scheme})
    if err != nil {
        return nil, fmt.Errorf("failed to create client: %w", err)
    }
    
    // Cache client
    c.clients[clusterName] = customerClient
    
    return customerClient, nil
}
```

**Usage:**
```go
// Controller automatically gets kubeconfig from Cluster API
clusterAPIClients, err := multicluster.NewClusterAPIClients(hubMgr.GetClient())

// Reference customer cluster by name (no manual kubeconfig needed)
customerClient, err := clusterAPIClients.GetClient(ctx, "customer-1")

// Write DPURule to customer cluster
customerClient.Create(ctx, dpuRule)
```

**Example Cluster API CR:**
```yaml
# Hub cluster creates this to provision customer cluster
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: customer-1
  namespace: default
spec:
  controlPlaneEndpoint:
    host: 192.168.1.10
    port: 6443
  # ... cluster configuration

---
# Cluster API automatically creates this secret
apiVersion: v1
kind: Secret
metadata:
  name: customer-1-kubeconfig
  namespace: default
type: cluster.x-k8s.io/secret
data:
  value: <base64-kubeconfig>  # Hub controller reads this
```

**Best for:** When hub provisions and manages customer clusters (managed K8s service).

---

#### **Approach 4: Agent-Based Pull Model (Reverse Direction)**

**How it works:** Customer clusters run agents that **pull** desired state from hub, rather than hub pushing.

**Advantages:**
- ✅ No inbound network access needed to customer clusters
- ✅ Customer clusters control what they accept
- ✅ Hub doesn't need customer credentials
- ✅ Works across restrictive firewalls

**Disadvantages:**
- ❌ More complex architecture
- ❌ Requires agent in every customer cluster
- ❌ Eventual consistency (not immediate)

**Architecture:**
```
Hub Cluster
  └─ Hub API Server (stores desired DPURules)
        ↑ (Pull via HTTPS)
        │
Customer Cluster Agent (DaemonSet/Deployment)
  ├─ Polls hub every 30s
  ├─ Fetches DPURules for this cluster
  └─ Applies locally to customer cluster
```

**Implementation:**

**Hub Controller (Simplified):**
```go
// Hub controller just creates DPURules in hub cluster
// No need to connect to customer clusters!

func (r *NetworkPolicyReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    var netpol networkingv1.NetworkPolicy
    if err := r.Client.Get(ctx, req.NamespacedName, &netpol); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }
    
    // Get target cluster from annotation
    clusterName := netpol.Annotations["dpu.io/target-cluster"]
    
    // Create DPURule in hub cluster with cluster label
    dpuRule := &dpuv1.DPURule{
        ObjectMeta: metav1.ObjectMeta{
            Name:      fmt.Sprintf("%s-%s", clusterName, netpol.Name),
            Namespace: "dpu-system",
            Labels: map[string]string{
                "target-cluster": clusterName,  // Agent filters by this
            },
        },
        Spec: dpuv1.DPURuleSpec{
            Rules: convertNetworkPolicyToFlowRules(&netpol),
        },
    }
    
    // Write to HUB cluster (not customer cluster)
    return ctrl.Result{}, r.Client.Create(ctx, dpuRule)
}
```

**Customer Cluster Agent:**
```go
// cmd/cluster-agent/main.go
// Runs in customer cluster, polls hub cluster

package main

import (
    "context"
    "time"
    
    "k8s.io/client-go/tools/clientcmd"
    ctrl "sigs.k8s.io/controller-runtime"
    "sigs.k8s.io/controller-runtime/pkg/client"
    
    dpuv1 "github.com/mycompany/dpu-operator/api/v1"
)

func main() {
    clusterName := os.Getenv("CLUSTER_NAME")  // "customer-1"
    hubKubeconfig := os.Getenv("HUB_KUBECONFIG")
    
    // Create client for local customer cluster
    localConfig := ctrl.GetConfigOrDie()
    localClient, err := client.New(localConfig, client.Options{Scheme: scheme})
    
    // Create client for hub cluster
    hubConfig, err := clientcmd.BuildConfigFromFlags("", hubKubeconfig)
    hubClient, err := client.New(hubConfig, client.Options{Scheme: scheme})
    
    // Poll hub every 30 seconds
    ticker := time.NewTicker(30 * time.Second)
    defer ticker.Stop()
    
    for range ticker.C {
        if err := syncFromHub(context.Background(), hubClient, localClient, clusterName); err != nil {
            log.Error(err, "failed to sync from hub")
        }
    }
}

func syncFromHub(ctx context.Context, hubClient, localClient client.Client, clusterName string) error {
    // Fetch DPURules from hub cluster with matching label
    var hubRules dpuv1.DPURuleList
    if err := hubClient.List(ctx, &hubRules,
        client.InNamespace("dpu-system"),
        client.MatchingLabels{"target-cluster": clusterName},
    ); err != nil {
        return err
    }
    
    log.Info("Fetched rules from hub", "count", len(hubRules.Items))
    
    // Apply each rule to local customer cluster
    for _, hubRule := range hubRules.Items {
        localRule := hubRule.DeepCopy()
        localRule.ResourceVersion = ""  // Clear for local create
        
        // Try to create in local cluster
        if err := localClient.Create(ctx, localRule); err != nil {
            if !errors.IsAlreadyExists(err) {
                return err
            }
            // Update existing
            var existingRule dpuv1.DPURule
            if err := localClient.Get(ctx, client.ObjectKeyFromObject(localRule), &existingRule); err != nil {
                return err
            }
            
            existingRule.Spec = localRule.Spec
            if err := localClient.Update(ctx, &existingRule); err != nil {
                return err
            }
        }
        
        log.Info("Synced rule to local cluster", "rule", localRule.Name)
    }
    
    return nil
}
```

**Deployment in Customer Cluster:**
```yaml
# Customer cluster deploys this agent
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cluster-sync-agent
  namespace: dpu-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cluster-sync-agent
  template:
    metadata:
      labels:
        app: cluster-sync-agent
    spec:
      containers:
      - name: agent
        image: myregistry/cluster-sync-agent:v1.0.0
        env:
        - name: CLUSTER_NAME
          value: "customer-1"
        - name: HUB_KUBECONFIG
          value: /config/hub.kubeconfig
        volumeMounts:
        - name: hub-kubeconfig
          mountPath: /config
          readOnly: true
      volumes:
      - name: hub-kubeconfig
        secret:
          secretName: hub-kubeconfig  # Customer creates this
```

**Hub Kubeconfig Setup (Customer does this):**
```bash
# Customer generates read-only kubeconfig for hub
# Customer has control - they create the credentials

# On customer cluster
kubectl create serviceaccount hub-reader -n dpu-system
kubectl create clusterrole hub-reader --verb=get,list,watch --resource=dpurules
kubectl create clusterrolebinding hub-reader --clusterrole=hub-reader --serviceaccount=dpu-system:hub-reader

# Get token
TOKEN=$(kubectl create token hub-reader -n dpu-system)

# Customer provides hub API server endpoint to agent
# Agent uses this to poll hub
```

**Best for:** Edge deployments, restrictive customer networks, zero-trust architectures.

---

### Comparison of Approaches

| Approach | Network Flow | Credentials | Latency | Complexity | Best For |
|----------|-------------|-------------|---------|-----------|----------|
| **Direct API** | Hub → Customer API | Hub holds customer kubeconfigs | Low (immediate) | ⭐⭐ Medium | Standard multi-tenant |
| **MCS API** | Hub ↔ Customer | Service mesh managed | Low | ⭐⭐⭐ High | Service mesh environments |
| **Cluster API** | Hub → Customer API | Auto-managed by CAPI | Low (immediate) | ⭐⭐⭐ High | Managed K8s platforms |
| **Agent Pull** | Customer → Hub API | Customer holds hub kubeconfig | Medium (30s poll) | ⭐⭐⭐ High | Edge, restrictive networks |

---

### Real-World Usage Patterns

**Google GKE/Anthos (Cluster API variant):**
```
Hub Cluster (Anthos Config Management)
  ├─ Uses Cluster API to register customer clusters
  ├─ Automatically gets kubeconfig for each cluster
  └─ Pushes Config Sync policies to customer clusters
```

**AWS EKS/EKS-Anywhere (Direct API):**
```
Management Account
  ├─ Stores kubeconfigs for each EKS cluster
  ├─ Uses IAM roles for cross-account access
  └─ Controllers write to customer cluster APIs directly
```

**Rancher Multi-Cluster (Agent Pull):**
```
Rancher Management Cluster
  ├─ Stores desired state
  └─ Customer clusters run rancher-agent
      └─ Agents poll management cluster every 30s
```

**Flux/ArgoCD GitOps (Git-based pull):**
```
Git Repository (single source of truth)
  ↑ (Pull)
Customer Clusters run Flux/ArgoCD agents
  └─ Agents watch Git for changes
  └─ Apply to local cluster
```

---

### Recommended Approach for Your Use Case

**If you control customer infrastructure:**
→ **Approach 1 (Direct API)** or **Approach 3 (Cluster API)**
- Simplest, lowest latency
- Full control over credentials

**If customers control their infrastructure:**
→ **Approach 4 (Agent Pull)**
- Customer approves hub access
- Works through firewalls
- Customer retains control

**Hybrid (most common in practice):**
```
┌──────────────────────────────────────────────┐
│ Hub Cluster                                  │
│ - Stores desired state as CRs                │
│ - Optionally pushes to managed clusters      │
└──────────────────────────────────────────────┘
         ↓ (push)              ↑ (pull)
    Direct API           Agent-based
         ↓                     ↑
┌────────────────┐   ┌────────────────┐
│ Managed        │   │ Customer       │
│ Clusters       │   │ Clusters       │
│ (you control)  │   │ (they control) │
└────────────────┘   └────────────────┘
```

---

## Multi-Cluster Network Topology

For detailed information about network architecture, VXLAN topology, and the critical importance of separating management and customer traffic, see:

**[Multi-Cluster Network Topology](../networking/multi-cluster-network-topology.md)**

Key topics covered:
- Control plane vs data plane separation
- VXLAN architecture options (static, multicast, BGP EVPN)
- Why management and customer traffic must be on separate networks
- Security, performance, and compliance considerations
- DPU dual-interface configuration
- Production deployment patterns

---

### Option 3: Local Control Plane

**Controller Code:** Same as Option 1, but deployed to each customer cluster independently.

**Deployment:**
```bash
# Deploy to customer-1 cluster
kubectl --kubeconfig customer-1.kubeconfig apply -f deploy/

# Deploy to customer-2 cluster
kubectl --kubeconfig customer-2.kubeconfig apply -f deploy/
```

---

## Comparison: Which Architecture?

| Criteria | Single Cluster | Hub-Spoke | Local Control Plane |
|----------|---------------|-----------|---------------------|
| **Complexity** | ⭐ Simple | ⭐⭐⭐ Complex | ⭐⭐ Medium |
| **Isolation** | ⭐ Low | ⭐⭐⭐ High | ⭐⭐⭐ Highest |
| **Network Requirements** | Nodes → API server | Hub → Customer APIs | None (self-contained) |
| **Auth Management** | ⭐ Simple | ⭐⭐⭐ Complex (N kubeconfigs) | ⭐⭐ Per-cluster |
| **Failure Isolation** | ⭐ Single point | ⭐⭐ Hub failure affects all | ⭐⭐⭐ Independent |
| **Multi-tenancy** | ❌ No | ✅ Yes | ✅ Yes |
| **Best For** | Single tenant | Multi-tenant SaaS | Edge/customer-managed |

### Recommendation by Use Case:

**Single Enterprise Deployment:**
→ **Option 1 (Single Cluster)**
- Simplest to operate
- All nodes in same cluster
- Example: Internal data center

**Multi-Tenant SaaS Platform:**
→ **Option 2 (Hub-Spoke)**
- Strong tenant isolation
- Centralized management
- Example: Managed Kubernetes service

**Customer-Managed Clusters:**
→ **Option 3 (Local Control Plane)**
- No external dependencies
- Customer owns control plane
- Example: On-prem edge deployments

---

## Image 1: Node Base Image (Join Cluster Only)

**Purpose:** Minimal Ubuntu image with kubelet/kubeadm to join cluster as worker node.

```dockerfile
# Dockerfile.node-base
FROM ubuntu:22.04

# Install system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        iptables \
        iproute2 \
        ipset \
        conntrack \
        socat \
        ebtables \
    && rm -rf /var/lib/apt/lists/*

# Add Kubernetes apt repository
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | \
    gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

RUN echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /" | \
    tee /etc/apt/sources.list.d/kubernetes.list

# Install kubelet and kubeadm (minimal for joining)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        kubelet=1.28.* \
        kubeadm=1.28.* \
    && rm -rf /var/lib/apt/lists/*

# Prevent automatic updates
RUN apt-mark hold kubelet kubeadm

# Configure kubelet
RUN mkdir -p /etc/kubernetes/manifests
RUN mkdir -p /var/lib/kubelet

# Enable kubelet service
RUN systemctl enable kubelet

CMD ["/bin/bash"]
```

**Usage:**
```bash
# Build
docker build -f Dockerfile.node-base -t node-base:v1.28 .

# On node, join cluster
kubeadm join <control-plane-ip>:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

**Size:** ~200-250MB  
**Use Case:** Base OS image for cluster nodes (not a container, used as VM/bare-metal OS)

---

## Image 2: Management Cluster CRD Controllers

**Purpose:** Controllers that run in management cluster, watch CRDs, orchestrate DPU rules.

### Dockerfile: Network Policy Controller

```dockerfile
# Dockerfile.network-policy-controller
# syntax=docker/dockerfile:1

# Build stage
FROM golang:1.21-bookworm AS builder

ARG VERSION=dev
ARG GIT_COMMIT=unknown
ARG BUILD_TIME

WORKDIR /workspace

# Dependencies
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

# Source code
COPY cmd/network-policy-controller/ cmd/network-policy-controller/
COPY pkg/ pkg/
COPY api/ api/

# Build
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-w -s \
              -X main.Version=${VERSION} \
              -X main.GitCommit=${GIT_COMMIT} \
              -X main.BuildTime=${BUILD_TIME}" \
    -o network-policy-controller ./cmd/network-policy-controller/main.go

# Runtime stage - minimal Ubuntu
FROM ubuntu:22.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

# Create nonroot user
RUN groupadd -g 65532 nonroot && \
    useradd -u 65532 -g nonroot -s /bin/bash -m nonroot

WORKDIR /app

COPY --from=builder --chown=nonroot:nonroot \
    /workspace/network-policy-controller .

USER nonroot:nonroot

ENTRYPOINT ["/app/network-policy-controller"]
```

### Controller Code Structure

```go
// cmd/network-policy-controller/main.go
package main

import (
    "context"
    "flag"
    "os"
    
    "k8s.io/client-go/kubernetes"
    "k8s.io/client-go/tools/clientcmd"
    ctrl "sigs.k8s.io/controller-runtime"
    "sigs.k8s.io/controller-runtime/pkg/log/zap"
    
    dpuv1 "github.com/mycompany/dpu-operator/api/v1"
    "github.com/mycompany/dpu-operator/controllers"
)

var (
    Version   = "dev"
    GitCommit = "unknown"
    BuildTime = "unknown"
)

func main() {
    var metricsAddr string
    var enableLeaderElection bool
    
    flag.StringVar(&metricsAddr, "metrics-bind-address", ":8080", 
        "The address the metric endpoint binds to.")
    flag.BoolVar(&enableLeaderElection, "leader-elect", false,
        "Enable leader election for controller manager.")
    flag.Parse()
    
    ctrl.SetLogger(zap.New(zap.UseDevMode(true)))
    
    mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
        Scheme:                 scheme,
        MetricsBindAddress:     metricsAddr,
        Port:                   9443,
        LeaderElection:         enableLeaderElection,
        LeaderElectionID:       "network-policy-controller.dpu.io",
    })
    if err != nil {
        setupLog.Error(err, "unable to start manager")
        os.Exit(1)
    }
    
    // Setup NetworkPolicy controller
    if err = (&controllers.NetworkPolicyReconciler{
        Client: mgr.GetClient(),
        Scheme: mgr.GetScheme(),
    }).SetupWithManager(mgr); err != nil {
        setupLog.Error(err, "unable to create controller", "controller", "NetworkPolicy")
        os.Exit(1)
    }
    
    setupLog.Info("starting manager", "version", Version, "commit", GitCommit)
    if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
        setupLog.Error(err, "problem running manager")
        os.Exit(1)
    }
}
```

```go
// controllers/networkpolicy_controller.go
package controllers

import (
    "context"
    
    networkingv1 "k8s.io/api/networking/v1"
    ctrl "sigs.k8s.io/controller-runtime"
    "sigs.k8s.io/controller-runtime/pkg/client"
    
    dpuv1 "github.com/mycompany/dpu-operator/api/v1"
)

type NetworkPolicyReconciler struct {
    client.Client
    Scheme *runtime.Scheme
}

// Reconcile NetworkPolicy changes
func (r *NetworkPolicyReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    log := ctrl.LoggerFrom(ctx)
    
    // Fetch NetworkPolicy
    var netpol networkingv1.NetworkPolicy
    if err := r.Get(ctx, req.NamespacedName, &netpol); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }
    
    // Get all pods matching this policy
    pods := &corev1.PodList{}
    if err := r.List(ctx, pods, 
        client.InNamespace(netpol.Namespace),
        client.MatchingLabels(netpol.Spec.PodSelector.MatchLabels),
    ); err != nil {
        return ctrl.Result{}, err
    }
    
    // For each pod, determine which DPU node it's on
    for _, pod := range pods.Items {
        nodeName := pod.Spec.NodeName
        
        // Create or update DPURule CR for this node
        dpuRule := &dpuv1.DPURule{
            ObjectMeta: metav1.ObjectMeta{
                Name:      fmt.Sprintf("%s-%s", netpol.Name, nodeName),
                Namespace: "dpu-system",
                Labels: map[string]string{
                    "node": nodeName,  // DPU agent watches for this
                },
            },
            Spec: dpuv1.DPURuleSpec{
                NodeName: nodeName,
                Rules:    convertNetworkPolicyToFlowRules(&netpol, &pod),
            },
        }
        
        if err := r.Create(ctx, dpuRule); err != nil {
            if !errors.IsAlreadyExists(err) {
                return ctrl.Result{}, err
            }
            // Update existing
            if err := r.Update(ctx, dpuRule); err != nil {
                return ctrl.Result{}, err
            }
        }
        
        log.Info("Created DPURule", "rule", dpuRule.Name, "node", nodeName)
    }
    
    return ctrl.Result{}, nil
}

func (r *NetworkPolicyReconciler) SetupWithManager(mgr ctrl.Manager) error {
    return ctrl.NewControllerManagedBy(mgr).
        For(&networkingv1.NetworkPolicy{}).
        Owns(&dpuv1.DPURule{}).
        Complete(r)
}

// Convert Kubernetes NetworkPolicy to DPU flow rules
func convertNetworkPolicyToFlowRules(netpol *networkingv1.NetworkPolicy, pod *corev1.Pod) []dpuv1.FlowRule {
    rules := []dpuv1.FlowRule{}
    
    // Ingress rules
    for _, ingress := range netpol.Spec.Ingress {
        for _, from := range ingress.From {
            for _, port := range ingress.Ports {
                rule := dpuv1.FlowRule{
                    Direction: "ingress",
                    Protocol:  string(*port.Protocol),
                    Port:      port.Port.IntVal,
                    Action:    "allow",
                    Priority:  100,
                }
                
                // Add source match from CIDR or pod selector
                if from.IPBlock != nil {
                    rule.SourceCIDR = from.IPBlock.CIDR
                }
                
                rules = append(rules, rule)
            }
        }
    }
    
    // Egress rules
    for _, egress := range netpol.Spec.Egress {
        for _, to := range egress.To {
            for _, port := range egress.Ports {
                rule := dpuv1.FlowRule{
                    Direction: "egress",
                    Protocol:  string(*port.Protocol),
                    Port:      port.Port.IntVal,
                    Action:    "allow",
                    Priority:  100,
                }
                
                if to.IPBlock != nil {
                    rule.DestCIDR = to.IPBlock.CIDR
                }
                
                rules = append(rules, rule)
            }
        }
    }
    
    return rules
}
```

### CRD Definitions

```yaml
# api/v1/dpurule_types.go
apiVersion: dpu.io/v1
kind: DPURule
metadata:
  name: netpol-allow-http-node1
  namespace: dpu-system
  labels:
    node: node-1  # DPU agent on node-1 watches for this
spec:
  nodeName: node-1
  rules:
  - direction: ingress
    protocol: TCP
    port: 80
    sourceCIDR: 10.0.0.0/16
    action: allow
    priority: 100
  
  - direction: ingress
    protocol: TCP
    port: 443
    sourceCIDR: 10.0.0.0/16
    action: allow
    priority: 100
  
  - direction: egress
    protocol: TCP
    destinationCIDR: 0.0.0.0/0
    action: allow
    priority: 50

status:
  conditions:
  - type: Programmed
    status: "True"
    lastTransitionTime: "2025-11-19T10:00:00Z"
    reason: FlowsProgrammed
    message: "Successfully programmed 3 flows on DPU"
  
  appliedRules: 3
  lastApplied: "2025-11-19T10:00:00Z"
```

### Deployment Manifest

```yaml
# deploy/network-policy-controller.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: dpu-system

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: network-policy-controller
  namespace: dpu-system

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: network-policy-controller
rules:
- apiGroups: ["networking.k8s.io"]
  resources: ["networkpolicies"]
  verbs: ["get", "list", "watch"]

- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]

- apiGroups: ["dpu.io"]
  resources: ["dpurules"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

- apiGroups: ["dpu.io"]
  resources: ["dpurules/status"]
  verbs: ["get", "update", "patch"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: network-policy-controller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: network-policy-controller
subjects:
- kind: ServiceAccount
  name: network-policy-controller
  namespace: dpu-system

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: network-policy-controller
  namespace: dpu-system
spec:
  replicas: 2  # HA with leader election
  selector:
    matchLabels:
      app: network-policy-controller
  template:
    metadata:
      labels:
        app: network-policy-controller
    spec:
      serviceAccountName: network-policy-controller
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        fsGroup: 65532
      
      containers:
      - name: controller
        image: myregistry/network-policy-controller:v1.0.0
        imagePullPolicy: IfNotPresent
        
        args:
        - --leader-elect
        - --metrics-bind-address=:8080
        
        ports:
        - name: metrics
          containerPort: 8080
          protocol: TCP
        
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8081
          initialDelaySeconds: 15
          periodSeconds: 20
        
        readinessProbe:
          httpGet:
            path: /readyz
            port: 8081
          initialDelaySeconds: 5
          periodSeconds: 10
        
        resources:
          limits:
            cpu: 500m
            memory: 256Mi
          requests:
            cpu: 100m
            memory: 128Mi
        
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
          readOnlyRootFilesystem: true
        
        volumeMounts:
        - name: tmp
          mountPath: /tmp
      
      volumes:
      - name: tmp
        emptyDir: {}
```

---

## Image 3: DPU Node Agent Controller

**Purpose:** Runs as DaemonSet on each DPU node, watches DPURule CRs with matching node label, programs hardware.

### Dockerfile: DPU Agent

```dockerfile
# Dockerfile.dpu-agent
# syntax=docker/dockerfile:1

# Build stage
FROM golang:1.21-bookworm AS builder

ARG VERSION=dev
ARG GIT_COMMIT=unknown
ARG BUILD_TIME

WORKDIR /workspace

# Dependencies
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

# Source
COPY cmd/dpu-agent/ cmd/dpu-agent/
COPY pkg/ pkg/
COPY api/ api/

# Build
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-w -s \
              -X main.Version=${VERSION} \
              -X main.GitCommit=${GIT_COMMIT} \
              -X main.BuildTime=${BUILD_TIME}" \
    -o dpu-agent ./cmd/dpu-agent/main.go

# Runtime stage - Ubuntu with DOCA and system tools
FROM ubuntu:22.04

# Install system dependencies for DPU operations
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        iproute2 \
        iptables \
        ipset \
        kmod \
        pciutils \
    && rm -rf /var/lib/apt/lists/*

# Install DOCA SDK (if needed)
# RUN apt-get update && \
#     apt-get install -y doca-all && \
#     rm -rf /var/lib/apt/lists/*

# Create nonroot user (may need elevated permissions)
RUN groupadd -g 65532 nonroot && \
    useradd -u 65532 -g nonroot -s /bin/bash -m nonroot

WORKDIR /app

COPY --from=builder /workspace/dpu-agent .

# DPU operations may require root
# Adjust based on actual capabilities needed
USER nonroot:nonroot

ENTRYPOINT ["/app/dpu-agent"]
```

### DPU Agent Controller Code

```go
// cmd/dpu-agent/main.go
package main

import (
    "context"
    "flag"
    "os"
    
    ctrl "sigs.k8s.io/controller-runtime"
    "sigs.k8s.io/controller-runtime/pkg/client"
    "sigs.k8s.io/controller-runtime/pkg/log/zap"
    
    dpuv1 "github.com/mycompany/dpu-operator/api/v1"
    "github.com/mycompany/dpu-operator/pkg/dpu"
)

var (
    Version   = "dev"
    GitCommit = "unknown"
    BuildTime = "unknown"
)

func main() {
    var metricsAddr string
    var nodeName string
    
    flag.StringVar(&metricsAddr, "metrics-bind-address", ":8080", 
        "The address the metric endpoint binds to.")
    flag.StringVar(&nodeName, "node-name", os.Getenv("NODE_NAME"),
        "The name of the node this agent is running on.")
    flag.Parse()
    
    if nodeName == "" {
        setupLog.Error(nil, "NODE_NAME must be set")
        os.Exit(1)
    }
    
    ctrl.SetLogger(zap.New(zap.UseDevMode(true)))
    
    // Initialize DPU hardware interface
    dpuClient, err := dpu.NewClient()
    if err != nil {
        setupLog.Error(err, "unable to initialize DPU client")
        os.Exit(1)
    }
    
    mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
        Scheme:             scheme,
        MetricsBindAddress: metricsAddr,
        Port:               9443,
        // No leader election - each node runs independently
    })
    if err != nil {
        setupLog.Error(err, "unable to start manager")
        os.Exit(1)
    }
    
    // Setup DPURule controller (watches only rules for this node)
    if err = (&controllers.DPURuleReconciler{
        Client:    mgr.GetClient(),
        Scheme:    mgr.GetScheme(),
        NodeName:  nodeName,
        DPUClient: dpuClient,
    }).SetupWithManager(mgr); err != nil {
        setupLog.Error(err, "unable to create controller", "controller", "DPURule")
        os.Exit(1)
    }
    
    setupLog.Info("starting DPU agent", 
        "version", Version, 
        "node", nodeName,
        "commit", GitCommit)
    
    if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
        setupLog.Error(err, "problem running manager")
        os.Exit(1)
    }
}
```

```go
// controllers/dpurule_controller.go
package controllers

import (
    "context"
    "fmt"
    
    ctrl "sigs.k8s.io/controller-runtime"
    "sigs.k8s.io/controller-runtime/pkg/client"
    "sigs.k8s.io/controller-runtime/pkg/predicate"
    
    dpuv1 "github.com/mycompany/dpu-operator/api/v1"
    "github.com/mycompany/dpu-operator/pkg/dpu"
)

type DPURuleReconciler struct {
    client.Client
    Scheme    *runtime.Scheme
    NodeName  string
    DPUClient *dpu.Client
}

func (r *DPURuleReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    log := ctrl.LoggerFrom(ctx)
    
    // Fetch DPURule
    var rule dpuv1.DPURule
    if err := r.Get(ctx, req.NamespacedName, &rule); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }
    
    // Check if rule is for this node
    if rule.Spec.NodeName != r.NodeName {
        // Should be filtered by predicate, but double check
        return ctrl.Result{}, nil
    }
    
    log.Info("Processing DPURule", "rule", rule.Name, "rulesCount", len(rule.Spec.Rules))
    
    // Program DPU hardware
    if err := r.programDPU(ctx, &rule); err != nil {
        log.Error(err, "failed to program DPU")
        
        // Update status - failed
        rule.Status.Conditions = []metav1.Condition{
            {
                Type:               "Programmed",
                Status:             metav1.ConditionFalse,
                LastTransitionTime: metav1.Now(),
                Reason:             "ProgrammingFailed",
                Message:            err.Error(),
            },
        }
        
        if err := r.Status().Update(ctx, &rule); err != nil {
            return ctrl.Result{}, err
        }
        
        return ctrl.Result{RequeueAfter: time.Minute}, err
    }
    
    // Update status - success
    rule.Status.Conditions = []metav1.Condition{
        {
            Type:               "Programmed",
            Status:             metav1.ConditionTrue,
            LastTransitionTime: metav1.Now(),
            Reason:             "FlowsProgrammed",
            Message:            fmt.Sprintf("Successfully programmed %d flows", len(rule.Spec.Rules)),
        },
    }
    rule.Status.AppliedRules = len(rule.Spec.Rules)
    rule.Status.LastApplied = metav1.Now()
    
    if err := r.Status().Update(ctx, &rule); err != nil {
        return ctrl.Result{}, err
    }
    
    log.Info("Successfully programmed DPU", "rules", len(rule.Spec.Rules))
    
    return ctrl.Result{}, nil
}

// Program DPU hardware with flow rules
func (r *DPURuleReconciler) programDPU(ctx context.Context, rule *dpuv1.DPURule) error {
    // Clear existing flows for this rule
    if err := r.DPUClient.ClearFlows(rule.Name); err != nil {
        return fmt.Errorf("failed to clear existing flows: %w", err)
    }
    
    // Install new flows
    for _, flowRule := range rule.Spec.Rules {
        flow := &dpu.Flow{
            Direction:       flowRule.Direction,
            Protocol:        flowRule.Protocol,
            Port:            flowRule.Port,
            SourceCIDR:      flowRule.SourceCIDR,
            DestinationCIDR: flowRule.DestCIDR,
            Action:          flowRule.Action,
            Priority:        flowRule.Priority,
        }
        
        if err := r.DPUClient.InstallFlow(flow); err != nil {
            return fmt.Errorf("failed to install flow: %w", err)
        }
    }
    
    return nil
}

func (r *DPURuleReconciler) SetupWithManager(mgr ctrl.Manager) error {
    // Only watch DPURules with label matching this node
    nodeFilter := predicate.NewPredicateFuncs(func(obj client.Object) bool {
        labels := obj.GetLabels()
        return labels["node"] == r.NodeName
    })
    
    return ctrl.NewControllerManagedBy(mgr).
        For(&dpuv1.DPURule{}).
        WithEventFilter(nodeFilter).
        Complete(r)
}
```

```go
// pkg/dpu/client.go
package dpu

import (
    "fmt"
    
    // Import DOCA SDK or OVS bindings
    // "github.com/nvidia/doca-go"
    // "github.com/openvswitch/ovs"
)

type Client struct {
    // Connection to DPU hardware
    // docaClient *doca.Client
    // ovsClient  *ovs.Client
}

type Flow struct {
    Direction       string
    Protocol        string
    Port            int32
    SourceCIDR      string
    DestinationCIDR string
    Action          string
    Priority        int32
}

func NewClient() (*Client, error) {
    // Initialize connection to DPU
    // This could be DOCA Flow API, OVS, or direct hardware access
    
    return &Client{
        // docaClient: docaClient,
    }, nil
}

func (c *Client) InstallFlow(flow *Flow) error {
    // Program hardware flow table
    // Example using DOCA Flow API:
    
    // match := doca.Match{
    //     Protocol: flow.Protocol,
    //     Port:     flow.Port,
    // }
    
    // action := doca.Action{
    //     Type: flow.Action, // "allow" or "drop"
    // }
    
    // return c.docaClient.InstallFlow(match, action, flow.Priority)
    
    fmt.Printf("Installing flow: %+v\n", flow)
    return nil
}

func (c *Client) ClearFlows(ruleID string) error {
    // Clear existing flows for this rule
    fmt.Printf("Clearing flows for rule: %s\n", ruleID)
    return nil
}
```

### DaemonSet Deployment

```yaml
# deploy/dpu-agent-daemonset.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: dpu-agent
  namespace: dpu-system
spec:
  selector:
    matchLabels:
      app: dpu-agent
  
  template:
    metadata:
      labels:
        app: dpu-agent
    spec:
      serviceAccountName: dpu-agent
      hostNetwork: true  # Access host network stack
      hostPID: true      # Access host processes (if needed)
      
      # Only schedule on nodes with DPUs
      nodeSelector:
        dpu.io/enabled: "true"
      
      # Tolerate control plane taints if needed
      tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      
      containers:
      - name: agent
        image: myregistry/dpu-agent:v1.0.0
        imagePullPolicy: IfNotPresent
        
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        
        args:
        - --node-name=$(NODE_NAME)
        - --metrics-bind-address=:8080
        
        ports:
        - name: metrics
          containerPort: 8080
          protocol: TCP
        
        resources:
          limits:
            cpu: 1000m
            memory: 512Mi
          requests:
            cpu: 200m
            memory: 256Mi
        
        securityContext:
          # May need elevated privileges for DPU operations
          privileged: true
          # Or use specific capabilities:
          # capabilities:
          #   add:
          #   - NET_ADMIN
          #   - SYS_ADMIN
        
        volumeMounts:
        # Mount host directories if needed
        - name: dpu-dev
          mountPath: /dev/dpu
        - name: sys
          mountPath: /sys
          readOnly: true
        - name: lib-modules
          mountPath: /lib/modules
          readOnly: true
      
      volumes:
      - name: dpu-dev
        hostPath:
          path: /dev
      - name: sys
        hostPath:
          path: /sys
      - name: lib-modules
        hostPath:
          path: /lib/modules

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dpu-agent
  namespace: dpu-system

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: dpu-agent
rules:
- apiGroups: ["dpu.io"]
  resources: ["dpurules"]
  verbs: ["get", "list", "watch"]

- apiGroups: ["dpu.io"]
  resources: ["dpurules/status"]
  verbs: ["get", "update", "patch"]

- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "watch"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dpu-agent
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: dpu-agent
subjects:
- kind: ServiceAccount
  name: dpu-agent
  namespace: dpu-system
```

---

## Build and Deployment Workflow

### Makefile for All Images

```makefile
# Makefile
REGISTRY ?= myregistry
VERSION ?= $(shell git describe --tags --always --dirty)

# Image names
NODE_BASE_IMG = $(REGISTRY)/node-base:v1.28
NETPOL_CONTROLLER_IMG = $(REGISTRY)/network-policy-controller:$(VERSION)
DPU_AGENT_IMG = $(REGISTRY)/dpu-agent:$(VERSION)

.PHONY: all
all: build-all push-all

# Build all images
.PHONY: build-all
build-all: build-node-base build-netpol-controller build-dpu-agent

.PHONY: build-node-base
build-node-base:
	docker build -f Dockerfile.node-base -t $(NODE_BASE_IMG) .

.PHONY: build-netpol-controller
build-netpol-controller:
	docker build -f Dockerfile.network-policy-controller \
		--build-arg VERSION=$(VERSION) \
		--build-arg GIT_COMMIT=$(shell git rev-parse HEAD) \
		--build-arg BUILD_TIME=$(shell date -u +"%Y-%m-%dT%H:%M:%SZ") \
		-t $(NETPOL_CONTROLLER_IMG) .

.PHONY: build-dpu-agent
build-dpu-agent:
	docker build -f Dockerfile.dpu-agent \
		--build-arg VERSION=$(VERSION) \
		--build-arg GIT_COMMIT=$(shell git rev-parse HEAD) \
		--build-arg BUILD_TIME=$(shell date -u +"%Y-%m-%dT%H:%M:%SZ") \
		-t $(DPU_AGENT_IMG) .

# Push all images
.PHONY: push-all
push-all: push-netpol-controller push-dpu-agent

.PHONY: push-netpol-controller
push-netpol-controller:
	docker push $(NETPOL_CONTROLLER_IMG)

.PHONY: push-dpu-agent
push-dpu-agent:
	docker push $(DPU_AGENT_IMG)

# Deploy to cluster
.PHONY: deploy
deploy:
	kubectl apply -f api/v1/dpurule_crd.yaml
	kubectl apply -f deploy/network-policy-controller.yaml
	kubectl apply -f deploy/dpu-agent-daemonset.yaml

# Clean
.PHONY: clean
clean:
	docker rmi $(NETPOL_CONTROLLER_IMG) $(DPU_AGENT_IMG) || true
```

### Complete Deployment Flow

```bash
# 1. Build CRDs
make generate  # Generate deepcopy, CRD manifests

# 2. Build images
make build-all

# 3. Push to registry
make push-all

# 4. Install CRDs
kubectl apply -f api/v1/dpurule_crd.yaml

# 5. Deploy management cluster controllers
kubectl apply -f deploy/network-policy-controller.yaml

# 6. Label DPU nodes
kubectl label node node-1 dpu.io/enabled=true
kubectl label node node-2 dpu.io/enabled=true

# 7. Deploy DPU agents (DaemonSet)
kubectl apply -f deploy/dpu-agent-daemonset.yaml

# 8. Verify
kubectl get pods -n dpu-system
# NAME                                         READY   STATUS    RESTARTS   AGE
# network-policy-controller-7d8f9c5b4d-abc12   1/1     Running   0          2m
# network-policy-controller-7d8f9c5b4d-def34   1/1     Running   0          2m
# dpu-agent-5678                               1/1     Running   0          1m
# dpu-agent-9012                               1/1     Running   0          1m

# 9. Test: Create a NetworkPolicy
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-http
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: web
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 80
EOF

# 10. Watch DPURule creation
kubectl get dpurules -n dpu-system -w

# 11. Check DPU agent logs
kubectl logs -n dpu-system dpu-agent-5678 --follow
```

---

## Summary

### Three Images Needed:

1. **Node Base Image** (~250MB)
   - Ubuntu 22.04 + kubelet + kubeadm
   - For joining nodes to cluster
   - Not a container - used as base OS

2. **Network Policy Controller** (~85MB)
   - Runs in management cluster (Deployment)
   - Watches NetworkPolicy CRDs
   - Creates DPURule CRs for each node
   - High availability (2 replicas + leader election)

3. **DPU Agent** (~150-180MB)
   - Runs on each DPU node (DaemonSet)
   - Watches DPURule CRs for its node
   - Programs DPU hardware (DOCA/OVS)
   - Updates status back to CR

### Data Flow:

```
User creates NetworkPolicy
    ↓
Network Policy Controller watches
    ↓
Controller creates DPURule CR (per node)
    ↓
DPU Agent (on node-1) watches DPURule (label: node=node-1)
    ↓
Agent programs BlueField DPU hardware
    ↓
Agent updates DPURule status
    ↓
User sees status: Programmed: True
```

This architecture separates concerns:
- **Management cluster**: Orchestration, CRD translation
- **DPU nodes**: Hardware programming, status reporting
- **Clean separation**: No direct hardware access from management cluster

---

## Build Optimization Techniques

### 1. Layer Caching Strategy

**Problem:** Every code change rebuilds everything.

**Solution:** Order Dockerfile commands by change frequency.

```dockerfile
# ❌ BAD: Changes to source code invalidate mod download
FROM golang:1.21-alpine AS builder
WORKDIR /workspace
COPY . .                    # Everything copied
RUN go mod download         # Re-downloads every time
RUN go build -o controller ./cmd

# ✅ GOOD: Dependencies cached separately
FROM golang:1.21-alpine AS builder
WORKDIR /workspace

# Step 1: Copy only dependency files (changes infrequently)
COPY go.mod go.sum ./
RUN go mod download

# Step 2: Copy source (changes frequently)
COPY . .
RUN go build -o controller ./cmd
```

**Result:** Dependency download only reruns when `go.mod`/`go.sum` change.

---

### 2. Build Arguments for Versioning

```dockerfile
FROM golang:1.21-alpine AS builder

ARG VERSION=dev
ARG GIT_COMMIT=unknown
ARG BUILD_TIME

WORKDIR /workspace
COPY . .

RUN go build \
    -ldflags="-X main.Version=${VERSION} \
              -X main.GitCommit=${GIT_COMMIT} \
              -X main.BuildTime=${BUILD_TIME} \
              -w -s" \
    -o controller ./cmd/controller

FROM gcr.io/distroless/static:nonroot
COPY --from=builder /workspace/controller /controller
USER 65532:65532
ENTRYPOINT ["/controller"]
```

**Build command:**
```bash
docker build \
  --build-arg VERSION=v1.2.3 \
  --build-arg GIT_COMMIT=$(git rev-parse HEAD) \
  --build-arg BUILD_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ") \
  -t my-controller:v1.2.3 .
```

**In code:**
```go
package main

var (
    Version   = "dev"
    GitCommit = "unknown"
    BuildTime = "unknown"
)

func main() {
    fmt.Printf("Version: %s\nCommit: %s\nBuilt: %s\n", 
               Version, GitCommit, BuildTime)
    // ... controller logic
}
```

---

### 3. Multi-Architecture Builds

**Why:** Support ARM64 (Raspberry Pi, Graviton) and AMD64 (x86).

**Using Docker Buildx:**
```bash
# Create builder (one-time setup)
docker buildx create --name multiarch --use
docker buildx inspect --bootstrap

# Build for multiple architectures
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t myregistry/my-controller:v1.0.0 \
  --push .
```

**Dockerfile with TARGETARCH:**
```dockerfile
FROM --platform=$BUILDPLATFORM golang:1.21-alpine AS builder

ARG TARGETOS
ARG TARGETARCH

WORKDIR /workspace
COPY . .

RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -o controller ./cmd/controller

FROM gcr.io/distroless/static:nonroot
COPY --from=builder /workspace/controller /controller
USER 65532:65532
ENTRYPOINT ["/controller"]
```

**Result:** Single manifest supports both architectures, Kubernetes pulls correct one automatically.

---

### 4. BuildKit Features

Enable BuildKit for faster builds:

```bash
# Enable BuildKit (Docker 18.09+)
export DOCKER_BUILDKIT=1

# Or in docker-compose.yml
version: "3.8"
services:
  build:
    build:
      context: .
      cache_from:
        - myregistry/my-controller:cache
```

**Advanced BuildKit Dockerfile:**
```dockerfile
# syntax=docker/dockerfile:1

FROM golang:1.21-alpine AS builder

# Enable BuildKit mount cache
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go mod download

COPY . .

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -o controller ./cmd

FROM gcr.io/distroless/static:nonroot
COPY --from=builder /workspace/controller /controller
USER 65532:65532
ENTRYPOINT ["/controller"]
```

**Benefits:**
- Build cache persists across builds
- 10-50x faster dependency downloads
- Shared cache between projects

---

## Security Best Practices

### 1. Non-Root User

**Why:** Limit privilege escalation if container is compromised.

```dockerfile
FROM alpine:3.19

# Create user
RUN addgroup -g 65532 -S controller && \
    adduser -u 65532 -S controller -G controller

# Change ownership if needed
RUN mkdir -p /data && chown controller:controller /data

USER controller:controller

ENTRYPOINT ["/controller"]
```

**In Kubernetes Manifest:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-controller
spec:
  securityContext:
    runAsUser: 65532
    runAsGroup: 65532
    runAsNonRoot: true
    fsGroup: 65532
  containers:
  - name: controller
    image: myregistry/my-controller:v1.0.0
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
      readOnlyRootFilesystem: true
```

---

### 2. Read-Only Root Filesystem

**Why:** Prevent malicious writes to container filesystem.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-controller
spec:
  template:
    spec:
      containers:
      - name: controller
        image: myregistry/my-controller:v1.0.0
        securityContext:
          readOnlyRootFilesystem: true
        volumeMounts:
        # Only writable directories are explicit volumes
        - name: tmp
          mountPath: /tmp
        - name: cache
          mountPath: /cache
      volumes:
      - name: tmp
        emptyDir: {}
      - name: cache
        emptyDir: {}
```

**Controller Code:**
```go
// Use /tmp or mounted volume for temp files
tmpDir := os.Getenv("TMPDIR")
if tmpDir == "" {
    tmpDir = "/tmp"  // Will be writable emptyDir
}
```

---

### 3. Image Scanning

**Tools:**

**Trivy (Recommended):**
```bash
# Scan local image
trivy image myregistry/my-controller:v1.0.0

# Scan in CI/CD
trivy image --exit-code 1 --severity HIGH,CRITICAL \
  myregistry/my-controller:v1.0.0

# Generate report
trivy image --format json -o scan-results.json \
  myregistry/my-controller:v1.0.0
```

**Snyk:**
```bash
snyk container test myregistry/my-controller:v1.0.0
```

**Anchore Grype:**
```bash
grype myregistry/my-controller:v1.0.0
```

**In CI/CD (GitHub Actions):**
```yaml
name: Build and Scan

on: [push]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Build image
        run: docker build -t my-controller:${{ github.sha }} .
      
      - name: Run Trivy vulnerability scanner
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: my-controller:${{ github.sha }}
          format: 'sarif'
          output: 'trivy-results.sarif'
      
      - name: Upload results to GitHub Security
        uses: github/codeql-action/upload-sarif@v2
        with:
          sarif_file: 'trivy-results.sarif'
```

---

### 4. Image Signing (Sigstore/Cosign)

**Why:** Verify image authenticity and integrity.

```bash
# Sign image
cosign sign --key cosign.key myregistry/my-controller:v1.0.0

# Verify signature
cosign verify --key cosign.pub myregistry/my-controller:v1.0.0
```

**In Kubernetes (with Kyverno):**
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signatures
spec:
  validationFailureAction: enforce
  rules:
  - name: verify-signature
    match:
      resources:
        kinds:
        - Pod
    verifyImages:
    - imageReferences:
      - "myregistry/my-controller:*"
      attestors:
      - count: 1
        entries:
        - keys:
            publicKeys: |-
              -----BEGIN PUBLIC KEY-----
              <your-public-key>
              -----END PUBLIC KEY-----
```

---

## Build Automation & CI/CD

### 1. Makefile for Local Development

```makefile
# Variables
REGISTRY ?= myregistry
IMAGE_NAME ?= my-controller
VERSION ?= $(shell git describe --tags --always --dirty)
GIT_COMMIT = $(shell git rev-parse HEAD)
BUILD_TIME = $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")

IMG ?= $(REGISTRY)/$(IMAGE_NAME):$(VERSION)

# Default target
.PHONY: all
all: build

# Build binary locally
.PHONY: build
build:
	CGO_ENABLED=0 go build -ldflags="-w -s \
		-X main.Version=$(VERSION) \
		-X main.GitCommit=$(GIT_COMMIT) \
		-X main.BuildTime=$(BUILD_TIME)" \
		-o bin/controller ./cmd/controller

# Build Docker image
.PHONY: docker-build
docker-build:
	docker build \
		--build-arg VERSION=$(VERSION) \
		--build-arg GIT_COMMIT=$(GIT_COMMIT) \
		--build-arg BUILD_TIME=$(BUILD_TIME) \
		-t $(IMG) .

# Push to registry
.PHONY: docker-push
docker-push:
	docker push $(IMG)

# Build and push multi-arch
.PHONY: docker-buildx
docker-buildx:
	docker buildx build \
		--platform linux/amd64,linux/arm64 \
		--build-arg VERSION=$(VERSION) \
		--build-arg GIT_COMMIT=$(GIT_COMMIT) \
		--build-arg BUILD_TIME=$(BUILD_TIME) \
		-t $(IMG) \
		--push .

# Run locally
.PHONY: run
run: build
	./bin/controller

# Run in Docker
.PHONY: docker-run
docker-run: docker-build
	docker run --rm \
		-v ~/.kube/config:/home/nonroot/.kube/config:ro \
		$(IMG)

# Deploy to Kubernetes
.PHONY: deploy
deploy:
	kubectl apply -f deploy/

# Clean
.PHONY: clean
clean:
	rm -rf bin/
	docker rmi $(IMG) || true
```

**Usage:**
```bash
# Build locally
make build

# Build image with auto-versioning
make docker-build

# Build and push multi-arch
make docker-buildx

# Build specific version
make docker-build VERSION=v1.2.3

# Push to custom registry
make docker-push REGISTRY=mycompany.azurecr.io
```

---

### 2. GitHub Actions Workflow

```yaml
name: Build and Push Controller Image

on:
  push:
    branches: [main]
    tags: ['v*']
  pull_request:
    branches: [main]

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
      security-events: write

    steps:
      - name: Checkout code
        uses: actions/checkout@v3
        with:
          fetch-depth: 0  # For git describe

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v2

      - name: Log in to Container Registry
        uses: docker/login-action@v2
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract metadata
        id: meta
        uses: docker/metadata-action@v4
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=ref,event=branch
            type=ref,event=pr
            type=semver,pattern={{version}}
            type=semver,pattern={{major}}.{{minor}}
            type=semver,pattern={{major}}
            type=sha,prefix={{branch}}-

      - name: Build and push
        uses: docker/build-push-action@v4
        with:
          context: .
          platforms: linux/amd64,linux/arm64
          push: ${{ github.event_name != 'pull_request' }}
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
          build-args: |
            VERSION=${{ steps.meta.outputs.version }}
            GIT_COMMIT=${{ github.sha }}
            BUILD_TIME=${{ github.event.head_commit.timestamp }}

      - name: Run Trivy scanner
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ steps.meta.outputs.version }}
          format: 'sarif'
          output: 'trivy-results.sarif'

      - name: Upload Trivy results
        uses: github/codeql-action/upload-sarif@v2
        if: always()
        with:
          sarif_file: 'trivy-results.sarif'
```

**Features:**
- Auto-versioning from git tags
- Multi-arch builds
- Push to GitHub Container Registry
- Vulnerability scanning
- Cache optimization
- Only pushes on main/tags (not PRs)

---

### 3. GitLab CI/CD

```yaml
# .gitlab-ci.yml
variables:
  DOCKER_DRIVER: overlay2
  DOCKER_TLS_CERTDIR: "/certs"
  IMAGE_TAG: $CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA

stages:
  - build
  - scan
  - push
  - deploy

build:
  stage: build
  image: docker:24
  services:
    - docker:24-dind
  before_script:
    - docker login -u $CI_REGISTRY_USER -p $CI_REGISTRY_PASSWORD $CI_REGISTRY
  script:
    - docker build 
        --build-arg VERSION=$CI_COMMIT_TAG
        --build-arg GIT_COMMIT=$CI_COMMIT_SHA
        --build-arg BUILD_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        -t $IMAGE_TAG .
    - docker push $IMAGE_TAG
  only:
    - main
    - tags

scan:
  stage: scan
  image: aquasec/trivy:latest
  script:
    - trivy image --exit-code 0 --severity HIGH,CRITICAL $IMAGE_TAG
  dependencies:
    - build
  only:
    - main
    - tags

push-latest:
  stage: push
  image: docker:24
  services:
    - docker:24-dind
  before_script:
    - docker login -u $CI_REGISTRY_USER -p $CI_REGISTRY_PASSWORD $CI_REGISTRY
  script:
    - docker pull $IMAGE_TAG
    - docker tag $IMAGE_TAG $CI_REGISTRY_IMAGE:latest
    - docker push $CI_REGISTRY_IMAGE:latest
  only:
    - main

deploy-staging:
  stage: deploy
  image: bitnami/kubectl:latest
  script:
    - kubectl set image deployment/my-controller 
        controller=$IMAGE_TAG
        -n staging
    - kubectl rollout status deployment/my-controller -n staging
  only:
    - main

deploy-production:
  stage: deploy
  image: bitnami/kubectl:latest
  script:
    - kubectl set image deployment/my-controller 
        controller=$CI_REGISTRY_IMAGE:$CI_COMMIT_TAG
        -n production
    - kubectl rollout status deployment/my-controller -n production
  only:
    - tags
  when: manual
```

---

## Image Registry Options

### 1. Public Registries

| Registry | URL | Notes |
|----------|-----|-------|
| Docker Hub | `docker.io` | Free public images, rate limits |
| GitHub Container Registry | `ghcr.io` | Integrated with GitHub Actions |
| Quay.io | `quay.io` | Free public, security scanning |
| Google Container Registry | `gcr.io` | Pay-per-use, fast global CDN |

**Example:**
```bash
# Docker Hub
docker push username/my-controller:v1.0.0

# GitHub Container Registry
docker push ghcr.io/username/my-controller:v1.0.0

# Quay
docker push quay.io/username/my-controller:v1.0.0
```

---

### 2. Private Registries

**Cloud Provider Registries:**

**AWS ECR:**
```bash
# Authenticate
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  123456789012.dkr.ecr.us-east-1.amazonaws.com

# Push
docker push 123456789012.dkr.ecr.us-east-1.amazonaws.com/my-controller:v1.0.0
```

**Azure ACR:**
```bash
# Authenticate
az acr login --name myregistry

# Push
docker push myregistry.azurecr.io/my-controller:v1.0.0
```

**Google GCR:**
```bash
# Authenticate
gcloud auth configure-docker

# Push
docker push gcr.io/my-project/my-controller:v1.0.0
```

**In Kubernetes:**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: regcred
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: <base64-encoded-docker-config>

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-controller
spec:
  template:
    spec:
      imagePullSecrets:
      - name: regcred
      containers:
      - name: controller
        image: myregistry.azurecr.io/my-controller:v1.0.0
```

---

### 3. Self-Hosted Registry (Harbor)

**Why:** Full control, vulnerability scanning, replication, RBAC.

**Install Harbor:**
```bash
# Using Helm
helm repo add harbor https://helm.goharbor.io
helm install harbor harbor/harbor \
  --set expose.type=ingress \
  --set expose.ingress.hosts.core=harbor.example.com \
  --set externalURL=https://harbor.example.com \
  --set persistence.enabled=true
```

**Push to Harbor:**
```bash
docker login harbor.example.com
docker tag my-controller:v1.0.0 harbor.example.com/library/my-controller:v1.0.0
docker push harbor.example.com/library/my-controller:v1.0.0
```

---

## Advanced Patterns

### 1. Sidecar Controller Pattern

**Use Case:** Controller + supporting container (metrics exporter, log forwarder).

```dockerfile
# Main controller
FROM golang:1.21-alpine AS controller-builder
WORKDIR /workspace
COPY . .
RUN CGO_ENABLED=0 go build -o controller ./cmd/controller

# Metrics exporter
FROM golang:1.21-alpine AS exporter-builder
WORKDIR /workspace
COPY metrics-exporter/ .
RUN CGO_ENABLED=0 go build -o exporter ./cmd/exporter

# Runtime image with both binaries
FROM gcr.io/distroless/static:nonroot

COPY --from=controller-builder /workspace/controller /controller
COPY --from=exporter-builder /workspace/exporter /exporter

USER 65532:65532

# Use shell script to run both (requires busybox base instead)
# Or deploy as separate containers in same pod
ENTRYPOINT ["/controller"]
```

**Better: Separate Containers in Same Pod:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-controller
spec:
  template:
    spec:
      containers:
      - name: controller
        image: myregistry/my-controller:v1.0.0
        ports:
        - containerPort: 8080
      
      - name: metrics-exporter
        image: myregistry/metrics-exporter:v1.0.0
        ports:
        - containerPort: 9090
```

---

### 2. Init Container for Setup

**Use Case:** Pre-flight checks, configuration generation, DB migrations.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-controller
spec:
  template:
    spec:
      initContainers:
      - name: setup
        image: myregistry/controller-setup:v1.0.0
        command: ["/setup"]
        volumeMounts:
        - name: config
          mountPath: /config
      
      containers:
      - name: controller
        image: myregistry/my-controller:v1.0.0
        volumeMounts:
        - name: config
          mountPath: /config
          readOnly: true
      
      volumes:
      - name: config
        emptyDir: {}
```

**Setup Dockerfile:**
```dockerfile
FROM alpine:3.19

RUN apk add --no-cache bash curl jq

COPY setup.sh /setup

RUN chmod +x /setup

USER 65532:65532

ENTRYPOINT ["/setup"]
```

---

### 3. Operator Bundle Images (OLM)

**Use Case:** Package operator for Operator Lifecycle Manager.

**Bundle Dockerfile:**
```dockerfile
FROM scratch

# Copy manifests
COPY manifests /manifests/
COPY metadata /metadata/

# Labels required by OLM
LABEL operators.operatorframework.io.bundle.mediatype.v1=registry+v1
LABEL operators.operatorframework.io.bundle.manifests.v1=manifests/
LABEL operators.operatorframework.io.bundle.metadata.v1=metadata/
LABEL operators.operatorframework.io.bundle.package.v1=my-operator
LABEL operators.operatorframework.io.bundle.channels.v1=stable
LABEL operators.operatorframework.io.bundle.channel.default.v1=stable
```

---

## Testing Images

### 1. Local Testing

```bash
# Test image locally
docker run --rm -it myregistry/my-controller:v1.0.0

# With Kubernetes context
docker run --rm -it \
  -v ~/.kube/config:/home/nonroot/.kube/config:ro \
  myregistry/my-controller:v1.0.0

# Override entrypoint for debugging
docker run --rm -it \
  --entrypoint /bin/sh \
  myregistry/my-controller:v1.0.0
```

---

### 2. Kind (Kubernetes in Docker)

```bash
# Create cluster
kind create cluster --name test

# Load image into kind
kind load docker-image myregistry/my-controller:v1.0.0 --name test

# Deploy
kubectl apply -f deploy/

# No need to push to registry!
```

---

### 3. Integration Tests

```bash
# Run e2e tests against image
go test ./test/e2e/... \
  -image=myregistry/my-controller:v1.0.0 \
  -kubeconfig=$HOME/.kube/config
```

---

## Troubleshooting

### Image Won't Start

```bash
# Check logs
kubectl logs deployment/my-controller

# Check events
kubectl describe pod <pod-name>

# Check image pull
kubectl get events --field-selector involvedObject.kind=Pod

# Verify image exists
docker manifest inspect myregistry/my-controller:v1.0.0
```

### ImagePullBackOff

```yaml
# Check image pull secrets
kubectl get secret regcred -o yaml

# Verify registry credentials
docker login myregistry.azurecr.io

# Check network connectivity
kubectl run -it --rm debug --image=alpine --restart=Never -- sh
# Inside pod:
nslookup myregistry.azurecr.io
```

### CrashLoopBackOff

```bash
# Check exit code
kubectl describe pod <pod-name> | grep "Exit Code"

# Run with different command for debugging
kubectl run debug --image=myregistry/my-controller:v1.0.0 \
  --command -- /bin/sh -c "while true; do sleep 30; done"

# Exec into running container
kubectl exec -it <pod-name> -- /bin/sh
```

---

## Best Practices Summary

✅ **DO:**
- Use multi-stage builds to minimize image size
- Use distroless or Alpine base images
- Run as non-root user (UID 65532)
- Scan images for vulnerabilities
- Version images with git tags/commits
- Use BuildKit for caching
- Sign images with Cosign
- Implement health checks
- Use read-only root filesystem
- Tag images immutably (no `:latest` in prod)

❌ **DON'T:**
- Include secrets in images
- Run as root
- Use `:latest` tag in production
- Include build tools in runtime image
- Hardcode registry URLs
- Skip vulnerability scanning
- Use mutable tags for deployed versions

---

## Reference

### Common ldflags

```bash
# Strip debug info and symbol table
-ldflags="-w -s"

# Add version info
-ldflags="-X main.Version=v1.0.0 -X main.GitCommit=abc123"

# Static linking
-ldflags="-extldflags '-static'"

# Combined
-ldflags="-w -s -X main.Version=v1.0.0 -extldflags '-static'"
```

### Image Size Targets

| Image Type | Target Size |
|------------|-------------|
| Go controller (distroless) | < 30 MB |
| Python controller | < 100 MB |
| Node.js controller | < 150 MB |
| With heavy dependencies | < 500 MB |

### Security Scanning Thresholds

```bash
# Fail build on HIGH or CRITICAL
trivy image --exit-code 1 --severity HIGH,CRITICAL image:tag

# Warn on MEDIUM
trivy image --exit-code 0 --severity MEDIUM image:tag

# Generate SARIF for GitHub Security
trivy image --format sarif -o results.sarif image:tag
```

---

## Next Steps

1. **Choose base image:** Distroless for security, Alpine for flexibility
2. **Set up multi-stage build:** Separate build and runtime stages
3. **Add CI/CD pipeline:** Automate builds on every commit/tag
4. **Implement scanning:** Add Trivy/Snyk to catch vulnerabilities
5. **Configure registry:** GitHub Container Registry, ECR, ACR, or Harbor
6. **Deploy with GitOps:** ArgoCD or Flux for automated deployment
7. **Monitor in production:** Prometheus metrics, distributed tracing
