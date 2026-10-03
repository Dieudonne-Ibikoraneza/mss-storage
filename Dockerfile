# syntax=docker/dockerfile:1
# Build official pinned source releases; the former public MinIO images no
# longer pull anonymously from Docker Hub or Quay in this environment.
FROM golang:1.25-bookworm AS minio-build
ARG MINIO_RELEASE=RELEASE.2025-10-15T17-29-55Z
ENV CGO_ENABLED=0 GOMAXPROCS=2 GOFLAGS=-p=2
WORKDIR /src
RUN git clone --depth 1 --branch "$MINIO_RELEASE" https://github.com/minio/minio.git .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go build -trimpath -ldflags "$(go run buildscripts/gen-ldflags.go)" -o /out/minio .

FROM golang:1.25-bookworm AS mc-build
ARG MC_RELEASE=RELEASE.2025-08-13T08-35-41Z
ENV CGO_ENABLED=0 GOMAXPROCS=2 GOFLAGS=-p=2
WORKDIR /src
RUN git clone --depth 1 --branch "$MC_RELEASE" https://github.com/minio/mc.git .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go build -trimpath -ldflags "$(go run buildscripts/gen-ldflags.go)" -o /out/mc .

FROM debian:bookworm-slim AS base
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 minio \
    && useradd --uid 10001 --gid minio --create-home minio

FROM base AS mc
COPY --from=mc-build /out/mc /usr/local/bin/mc
COPY --from=mc-build /src/LICENSE /licenses/minio-mc-LICENSE
USER minio
ENTRYPOINT ["mc"]

FROM base AS minio
COPY --from=minio-build /out/minio /usr/local/bin/minio
COPY --from=minio-build /src/LICENSE /licenses/minio-LICENSE
RUN mkdir -p /data && chown minio:minio /data
USER minio
VOLUME ["/data"]
EXPOSE 9000 9001
ENTRYPOINT ["minio"]
CMD ["server", "/data", "--console-address", ":9001"]
