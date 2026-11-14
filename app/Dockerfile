# syntax=docker/dockerfile:1

# Build context is the app/ directory.
#
#   docker build -t simplarr app/
#   docker buildx build --platform linux/arm64 -t simplarr app/    (Raspberry Pi)
#
# Build stages run on the build machine's own architecture and cross-compile,
# so an arm64 image needs no emulation.

# --- 1. Web UI -------------------------------------------------------------
FROM --platform=$BUILDPLATFORM node:24-alpine AS web
WORKDIR /src/web
COPY web/package.json web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY web/ ./
# vite.config.ts writes to ../internal/webui/dist, which is /src/internal/webui/dist here.
RUN npm run build

# --- 2. Go binary with the UI embedded -------------------------------------
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
COPY --from=web /src/internal/webui/dist ./internal/webui/dist
ARG TARGETOS
ARG TARGETARCH
ARG VERSION=dev
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -tags webdist -trimpath -ldflags="-s -w -X main.version=${VERSION}" \
    -o /out/simplarr ./cmd/simplarr \
 && mkdir -p /out/data

# --- 3. Runtime: distroless, no shell, non-root ----------------------------
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/simplarr /simplarr
# Writable default for `docker run` without a volume. Compose bind-mounts over it.
COPY --from=build --chown=65532:65532 /out/data /data
USER 65532:65532
EXPOSE 8080
# The image has no curl, so the binary probes itself.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD ["/simplarr", "healthcheck"]
ENTRYPOINT ["/simplarr"]
CMD ["serve"]
