# MinIO Client (`mc`) built from its last upstream source release.
#
# The `minio-init` job needs `mc` for the MinIO admin API (users, policies,
# anonymous bucket access), which RustFS also serves. MinIO no longer publishes
# pullable `mc` images (Docker Hub withdrawn, quay.io refuses anonymous pulls),
# so this image builds the unmodified source and is published as
# ghcr.io/faridlab/mc:<MC_RELEASE>. See README.md next to this file.

ARG MC_RELEASE=RELEASE.2025-08-13T08-35-41Z

# Build on the host's platform and cross-compile, so a multi-arch build does
# not run the Go toolchain under emulation.
FROM --platform=$BUILDPLATFORM golang:1.25.14-alpine3.24 AS build
ARG MC_RELEASE
ARG TARGETOS
ARG TARGETARCH
RUN apk add --no-cache git
WORKDIR /src
RUN git clone --depth 1 --branch "${MC_RELEASE}" https://github.com/minio/mc.git .
ENV CGO_ENABLED=0 GOTOOLCHAIN=local
# Same flags as upstream's `make build`, with the release tag baked into `mc --version`.
RUN GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" go build -trimpath -tags kqueue \
      -ldflags "$(MC_RELEASE=RELEASE go run buildscripts/gen-ldflags.go "${MC_RELEASE#RELEASE.}")" \
      -o /out/mc . \
 && mkdir -p /out/licenses && cp LICENSE CREDITS /out/licenses/

# Alpine rather than distroless: the bootstrap jobs run a shell script around `mc`.
FROM alpine:3.24.2
ARG MC_RELEASE
RUN apk add --no-cache ca-certificates
COPY --from=build /out/mc /usr/bin/mc
COPY --from=build /out/licenses /licenses
LABEL org.opencontainers.image.title="mc" \
      org.opencontainers.image.description="MinIO Client built unmodified from source tag ${MC_RELEASE}" \
      org.opencontainers.image.source="https://github.com/minio/mc/tree/${MC_RELEASE}" \
      org.opencontainers.image.version="${MC_RELEASE}" \
      org.opencontainers.image.licenses="AGPL-3.0-only"
ENTRYPOINT ["mc"]
