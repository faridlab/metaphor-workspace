# `mc` bootstrap image

The `minio-init` job in [`../../compose.yaml`](../../compose.yaml) and
[`../../compose.dev.yaml`](../../compose.dev.yaml) creates the buckets, the anonymous-read policy on
the public bucket, and the least-privilege service user. Creating the user and its policy needs the
MinIO admin API (`mc admin …`), which RustFS also serves, so plain S3 tools are not enough.

MinIO stopped publishing pullable `mc` images: the Docker Hub images were withdrawn and quay.io
refuses anonymous pulls. This directory builds the client from source instead.

| | |
|---|---|
| Upstream source | https://github.com/minio/mc, tag [`RELEASE.2025-08-13T08-35-41Z`](https://github.com/minio/mc/tree/RELEASE.2025-08-13T08-35-41Z) (the last release; the repository is archived) |
| License | **AGPL-3.0**. The binary is built unmodified; `LICENSE` and `CREDITS` ship in `/licenses` |
| Published as | `ghcr.io/faridlab/mc:RELEASE.2025-08-13T08-35-41Z` (the tag is the upstream source tag) |
| Base | `alpine` (the jobs run a shell script around `mc`), built with `golang` on Alpine |

This image is temporary. The plan is to move the bootstrap into the service binary
(`<service> storage init`, using the S3 SDK and the RustFS admin API), which removes it.

## Build and publish

```bash
cd deployment/images/mc
docker buildx build --platform linux/amd64,linux/arm64 \
  -t ghcr.io/faridlab/mc:RELEASE.2025-08-13T08-35-41Z --push .
```

To build another upstream release, pass `--build-arg MC_RELEASE=<tag>` and use the same tag in the
image name. Pin it in every `minio-init` job.

## Check

```bash
docker run --rm ghcr.io/faridlab/mc:RELEASE.2025-08-13T08-35-41Z --version
```
