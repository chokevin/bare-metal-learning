# Building Kubernetes Controller Images

## Overview

Custom Kubernetes controllers need to be packaged as container images. This guide covers best practices for building secure, minimal, and production-ready controller images.

---

## Multi-Stage Builds (Essential)

**Why:** Separate build dependencies from runtime, minimize image size, improve security.

### Basic Go Controller

```dockerfile
# Stage 1: Build
FROM golang:1.21-alpine AS builder

WORKDIR /workspace
COPY go.mod go.sum ./
RUN go mod download

COPY cmd/ cmd/
COPY pkg/ pkg/
COPY api/ api/

# Static binary (no libc dependency)
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-w -s" \
    -a -o controller ./cmd/controller/main.go

# Stage 2: Runtime
FROM gcr.io/distroless/static:nonroot

COPY --from=builder /workspace/controller /controller
USER 65532:65532

ENTRYPOINT ["/controller"]
```

**Results:**
- Build stage: ~1GB (Go compiler, tools)
- Runtime stage: Small (binary + distroless base)
- No shell, package manager, or unnecessary tools in production

---

## Base Image Comparison

### 1. Distroless (Recommended for Most)

| Image | Size | Use Case | Contents |
|-------|------|----------|----------|
| `gcr.io/distroless/static:nonroot` | Minimal | Static Go binaries | Minimal files, nonroot user |
| `gcr.io/distroless/base:nonroot` | Small | Dynamic binaries (needs glibc) | glibc, CA certs, timezone |

**Pros:**
- ✅ Minimal attack surface (no shell, no package manager)
- ✅ Smallest size
- ✅ Best for security-sensitive environments

**Cons:**
- ❌ Can't `kubectl exec` for debugging (no shell)
- ❌ Can't install runtime dependencies

**Example:**
```dockerfile
FROM gcr.io/distroless/static:nonroot
COPY --from=builder /workspace/controller /controller
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
USER nonroot:nonroot
ENTRYPOINT ["/controller"]
```

### 2. Alpine (Flexible)

**Size:** Small base  
**Use when:** Need shell for debugging, runtime package installation

**Pros:**
- ✅ Small footprint
- ✅ Has shell (`/bin/sh`)
- ✅ Package manager (`apk`)

**Cons:**
- ⚠️ Slightly larger attack surface
- ⚠️ Uses `musl` libc (not `glibc` - compatibility issues possible)

**Example:**
```dockerfile
FROM alpine:latest
RUN apk add --no-cache ca-certificates
COPY --from=builder /workspace/controller /controller
USER nonroot:nonroot
ENTRYPOINT ["/controller"]
```

### 3. Ubuntu (Standard for Complex Controllers)

**Size:** Medium base  
**Use when:** Need `kubectl`, `systemd`, or standard tooling

**Pros:**
- ✅ Full `glibc` compatibility
- ✅ Standard package manager (`apt`)
- ✅ Familiar environment

**Cons:**
- ⚠️ Larger size
- ⚠️ More packages = larger attack surface

**Example:**
```dockerfile
FROM ubuntu:latest
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /workspace/controller /controller
USER nonroot:nonroot
ENTRYPOINT ["/controller"]
```

---

## Decision Tree

```
Does your controller need kubectl/complex tools?
    Yes → Use Ubuntu
    No ↓

Can you build a static binary (CGO_ENABLED=0)?
    Yes → Use Distroless Static
    No ↓

Need debugging with shell?
    Yes → Use Alpine
    No → Use Distroless Base
```

---

## Key Patterns

### Pattern 1: Minimal Controller (Recommended)

**Use case:** Standard K8s controller (no special tools needed)

```dockerfile
FROM golang:alpine AS builder
WORKDIR /workspace
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-w -s" -o controller ./cmd/controller

FROM gcr.io/distroless/static:nonroot
COPY --from=builder /workspace/controller /controller
USER nonroot:nonroot
ENTRYPOINT ["/controller"]
```

**Size:** Small  
**Security:** Minimal attack surface  
**Deployment:** Works everywhere

---

### Pattern 2: Controller with kubectl

**Use case:** Controller needs to shell out to `kubectl` commands

```dockerfile
FROM golang:alpine AS builder
WORKDIR /workspace
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-w -s" -o controller ./cmd/controller

FROM ubuntu:latest
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates curl && \
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
    chmod +x kubectl && \
    mv kubectl /usr/local/bin/ && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /workspace/controller /controller
USER nonroot:nonroot
ENTRYPOINT ["/controller"]
```

**Size:** Medium  
**Use:** Cluster API providers, operators that exec `kubectl`

---

### Pattern 3: DaemonSet Node Controller

**Use case:** Controller runs on every node, needs host filesystem access

```dockerfile
FROM golang:alpine AS builder
WORKDIR /workspace
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-w -s" -o node-controller ./cmd/node-controller

FROM alpine:latest
RUN apk add --no-cache \
    ca-certificates \
    iptables \
    iproute2 \
    util-linux
COPY --from=builder /workspace/node-controller /node-controller
ENTRYPOINT ["/node-controller"]
```

**Deployment:**
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-controller
spec:
  template:
    spec:
      hostNetwork: true
      hostPID: true
      containers:
      - name: node-controller
        image: node-controller:latest
        securityContext:
          privileged: true
        volumeMounts:
        - name: host-root
          mountPath: /host
      volumes:
      - name: host-root
        hostPath:
          path: /
```

**Use:** CNI plugins, device plugins, node-level controllers

---

### Pattern 4: Operator with Helm/Tooling

**Use case:** Operator that manages Helm charts or complex deployments

```dockerfile
FROM golang:alpine AS builder
WORKDIR /workspace
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-w -s" -o operator ./cmd/operator

FROM ubuntu:latest
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates curl git && \
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /workspace/operator /operator
USER nonroot:nonroot
ENTRYPOINT ["/operator"]
```

**Size:** Larger  
**Use:** Helm operators, GitOps controllers

---

## Best Practices

### 1. Always Use Multi-Stage Builds

**Why:** Separates build dependencies from runtime

```dockerfile
# ✅ Good: Build in one stage, run in another
FROM golang:alpine AS builder
RUN go build -o app .

FROM alpine:latest
COPY --from=builder /workspace/app /app
```

```dockerfile
# ❌ Bad: Everything in one stage
FROM golang:alpine
COPY . .
RUN go build -o app .
ENTRYPOINT ["/app"]
# Result: Very large image with compiler, source code, etc.
```

### 2. Keep APT/apk Cache Clean

```dockerfile
# ✅ Good: Clean in same RUN command
RUN apt-get update && \
    apt-get install -y ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# ❌ Bad: Separate RUN commands (layers not collapsed)
RUN apt-get update
RUN apt-get install -y ca-certificates
RUN rm -rf /var/lib/apt/lists/*  # Doesn't reduce image size!
```

### 3. Use --no-install-recommends

```dockerfile
# ✅ Good: Only install required packages
RUN apt-get install -y --no-install-recommends ca-certificates

# ❌ Bad: Installs 10x more packages
RUN apt-get install -y ca-certificates
```

### 4. Pin Versions

```dockerfile
# ✅ Good: Pin base image version
FROM golang:alpine AS builder
FROM gcr.io/distroless/static:nonroot-amd64@sha256:abc123...

# ❌ Bad: Floating tags (breaks reproducibility)
FROM golang:latest AS builder
FROM gcr.io/distroless/static:nonroot
```

### 5. Use Nonroot User

```dockerfile
# ✅ Good: Run as nonroot user
FROM alpine:latest
RUN addgroup -S nonroot && \
    adduser -S nonroot -G nonroot
USER nonroot:nonroot
ENTRYPOINT ["/app"]

# ❌ Bad: Run as root (security risk)
FROM alpine:latest
ENTRYPOINT ["/app"]  # Runs as UID 0!
```

### 6. Add Health Checks

```dockerfile
FROM gcr.io/distroless/static:nonroot
COPY --from=builder /workspace/controller /controller

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD ["/controller", "--health-check"]

ENTRYPOINT ["/controller"]
```

**In Go code:**
```go
func healthCheckHandler(w http.ResponseWriter, r *http.Request) {
    w.WriteHeader(http.StatusOK)
    w.Write([]byte("healthy"))
}

// In main():
http.HandleFunc("/healthz", healthCheckHandler)
go http.ListenAndServe(":8081", nil)
```

### 7. Optimize Layer Caching

```dockerfile
# ✅ Good: Copy go.mod first (cached unless dependencies change)
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN go build -o app .

# ❌ Bad: Copy everything first (cache busted on any file change)
COPY . .
RUN go mod download
RUN go build -o app .
```

---

## Security Best Practices

### 1. Scan Images for Vulnerabilities

```bash
# Use trivy for vulnerability scanning
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy image my-controller:latest
```

### 2. Use Distroless for Production

Distroless images have **zero** CVEs because they contain almost nothing.

```dockerfile
# ✅ Best: Distroless (no shell, no package manager)
FROM gcr.io/distroless/static:nonroot

# ⚠️ OK: Alpine (minimal but has shell)
FROM alpine:3.18

# ❌ Avoid: Ubuntu (many packages = more CVEs)
FROM ubuntu:22.04
```

### 3. Drop Capabilities

```yaml
# In Pod spec
securityContext:
  allowPrivilegeEscalation: false
  runAsNonRoot: true
  runAsUser: <nonroot_uid>
  capabilities:
    drop:
    - ALL
  seccompProfile:
    type: RuntimeDefault
```

---

## Debugging Without Shell

### Problem: Distroless has no shell

**Solution 1: Use ephemeral containers (K8s 1.25+)**

```bash
kubectl debug -it my-pod --image=busybox --target=controller
```

**Solution 2: Use a debug variant**

```dockerfile
# Production
FROM gcr.io/distroless/static:nonroot AS prod
COPY --from=builder /workspace/controller /controller
ENTRYPOINT ["/controller"]

# Debug (includes busybox shell)
FROM gcr.io/distroless/static:debug-nonroot AS debug
COPY --from=builder /workspace/controller /controller
ENTRYPOINT ["/controller"]
```

Build debug image:
```bash
docker build --target=debug -t my-controller:debug .
```

---

## Complete Example: Production-Ready Controller

```dockerfile
# syntax=docker/dockerfile:1.4

# Build stage
FROM golang:1.21.5-alpine3.18 AS builder

WORKDIR /workspace

# Cache dependencies
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

# Build binary
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-w -s -X main.version=1.0.0" \
    -a -o controller ./cmd/controller/main.go

# Runtime stage
FROM gcr.io/distroless/static:nonroot-amd64@sha256:abc123...

COPY --from=builder /workspace/controller /controller

USER 65532:65532

HEALTHCHECK --interval=30s --timeout=5s CMD ["/controller", "--health-check"]

ENTRYPOINT ["/controller"]
```

**Features:**
- ✅ Multi-stage build (minimal runtime)
- ✅ Distroless base (secure)
- ✅ Nonroot user (secure)
- ✅ Health check (K8s integration)
- ✅ Build cache mounts (faster builds)
- ✅ Static binary (no dependencies)
- ✅ Version info in binary (`-X main.version`)

---

## Common Mistakes

#### Issue: Controller runs as root

**Problem:**
```dockerfile
FROM alpine:latest
COPY controller /controller
ENTRYPOINT ["/controller"]  # Runs as UID 0!
```

**Fix:** Add `USER nonroot:nonroot`

### ❌ Large Images

```dockerfile
FROM golang:1.21-alpine
COPY . .
RUN go build -o controller .
ENTRYPOINT ["/controller"]  # 400MB image!
```

**Fix:** Use multi-stage build

### ❌ Floating Tags

```dockerfile
FROM golang:latest AS builder  # Breaks in 6 months!
```

**Fix:** Pin version: `FROM golang:1.21.5-alpine3.18`

### ❌ Forgetting CA Certificates

```dockerfile
FROM scratch
COPY controller /controller
ENTRYPOINT ["/controller"]  # Can't make HTTPS requests!
```

**Fix:** Copy CA certs or use distroless/base

---

## Quick Reference

| Requirement | Recommended Base | Size | Security |
|-------------|------------------|------|----------|
| Standard controller | `distroless/static:nonroot` | 20MB | ⭐⭐⭐ |
| Need glibc | `distroless/base:nonroot` | 25MB | ⭐⭐⭐ |
| Need debugging | `alpine:3.18` | 30MB | ⭐⭐ |
| Need kubectl | `ubuntu:22.04` | 80MB | ⭐ |
| Node-level controller | `alpine:3.18` | 40MB | ⭐⭐ |

**Default choice:** `gcr.io/distroless/static:nonroot`

---

## Resources

- [Distroless Images](https://github.com/GoogleContainerTools/distroless)
- [Multi-stage builds](https://docs.docker.com/build/building/multi-stage/)
- [Dockerfile best practices](https://docs.docker.com/develop/dev-best-practices/)
- [Kubebuilder](https://book.kubebuilder.io/)
