# Magnificat storage

Standalone MinIO deployment for Magnificat Smart Space.
It shares the external `magnificat-backend` network with the API and database.
Objects persist in `magnificat-storage_minio-data`, independently of containers.

## Deploy

Install Docker Engine and Docker Compose v2, and start
[the database](https://github.com/Dieudonne-Ibikoraneza/mss-db/blob/main/README.md#deploy) first. The complete order is
**database → storage → backend → frontend**. Clone the repository into the workspace as `storage/`, then initialize it:

```sh
git clone https://github.com/Dieudonne-Ibikoraneza/mss-storage.git storage
cd storage
./docker.sh --init-env
```

For an existing checkout, run `cd storage` without cloning again. Keep its
`.env` and skip `--init-env`. Configure:

| Variable | Value |
| --- | --- |
| `BACKEND_NETWORK` | Same network as the database and backend |
| `MINIO_ROOT_USER` | Console login and initial application access key; default `magnificat-storage` |
| `MINIO_ROOT_PASSWORD` | Generate with `openssl rand -hex 32`; also set backend `MINIO_SECRET_KEY` |
| `MINIO_BUCKET` | `magnificat-smart-space`, matching the backend |
| `MINIO_API_PORT` | Host API port; default `9002` |
| `MINIO_CONSOLE_PORT` | Host console port; default `9003` |

From `storage/`, validate and start:

```sh
./docker.sh --config
./docker.sh --up
./docker.sh --status
```

The script creates the shared network, builds the server/client images, starts
MinIO, waits for health, and initializes the private bucket. Bucket creation is
safe to repeat. `./scripts/init-bucket.sh` repeats initialization explicitly.

This project builds MinIO from official pinned source releases:
server `RELEASE.2025-10-15T17-29-55Z` and client
`RELEASE.2025-08-13T08-35-41Z`. The multi-stage images include upstream licenses,
run as an unprivileged user, and do not include local environment files. The
first build downloads Go dependencies and can take several minutes. Later
builds reuse the Docker build cache. Use `--no-build` for existing images and
`--pull` to refresh base images when building.

## Connect the API

Set these in `../server/.env.docker`:

```dotenv
STORAGE_DRIVER=minio
MINIO_ENDPOINT=magnificat-minio
MINIO_API_PORT=9000
MINIO_USE_SSL=false
MINIO_ACCESS_KEY=magnificat-storage
MINIO_SECRET_KEY=<same as MINIO_ROOT_PASSWORD>
MINIO_BUCKET=magnificat-smart-space
MINIO_REGION=us-east-1
```

The access key must match `MINIO_ROOT_USER` for this initial setup. A dedicated
application key with equivalent bucket access can be used instead. The bucket
name must match storage `.env`. MinIO requires lowercase S3 bucket names, so the
application uses one physical bucket with logical namespaces:

| Existing application bucket | MinIO object prefix |
| --- | --- |
| Products | `products/` |
| Collections | `collections/` |
| RoomThumbnails | `roomthumbnails/` |
| RecommendationVisuals | `recommendationvisuals/` |
| RoomPhotos | `roomphotos/` |

The existing stored relative paths are preserved after those prefixes. For
example, `Products` path `products/a.webp` becomes physical object key
`products/products/a.webp`. Images stay private: the API reads their bytes and
the frontend's existing opaque image proxy serves them. MinIO hostnames and
credentials are not sent to browsers. Non-product image tokens expire after
one hour; catalog image URLs retain their existing behavior.

## Ports and console

Both ports bind to localhost: API `127.0.0.1:9002`, console
`127.0.0.1:9003`. Containers use `magnificat-minio:9000`, regardless of the host
port. For native backend development, use `MINIO_ENDPOINT=localhost` and
`MINIO_API_PORT=9002` instead. Browse the console via an SSH tunnel, or configure
an HTTPS reverse proxy and set `MINIO_BROWSER_REDIRECT_URL` to its console
origin. The browser-facing application does not need a public MinIO API URL.

## Verify and browse files

`./docker.sh --status` should show MinIO as healthy. For the default host port:

```sh
curl --fail http://localhost:9002/minio/health/ready
```

Open [the local console](http://localhost:9003) and sign in with
`MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD` from `.env`. Open the
`magnificat-smart-space` bucket to preview or download objects. Product images
are under `products/products/`; other namespaces are listed above. Use the host
ports configured in `.env` if you changed the defaults.

Continue with [the backend](https://github.com/Dieudonne-Ibikoraneza/mss-server/blob/HEAD/README.md#production-docker), then
[the frontend](https://github.com/Dieudonne-Ibikoraneza/magnificat-smart-space-client/blob/HEAD/README.md#docker-deployment).
The shared workspace also contains `DOCKER-LOCAL.md` for the local test setup
and `DOCKER.md` for the complete deployment guide.

## Management

```sh
./docker.sh --status
./docker.sh --logs --follow
./docker.sh --up --no-build
./docker.sh --restart
./docker.sh --stop
./docker.sh --down
```

`--down` preserves the named data volume and backend network. Keep independent
backups of the stored objects; the volume survives container replacement but
is not a backup against disk failure. Existing Supabase files are not copied
automatically: copy them to the corresponding namespace prefixes before
switching an existing installation to `STORAGE_DRIVER=minio`. Supabase support
remains available during a planned cutover.

`./scripts/deploy.sh` forwards the same flags to `docker.sh`. Use `--help` for
custom env files, project names, and health timeouts. `MINIO_VOLUME` customizes
the named volume for isolated test deployments; keep it stable between starts.

References: [MinIO server source release](https://github.com/minio/minio/releases/tag/RELEASE.2025-10-15T17-29-55Z),
[MinIO JavaScript SDK](https://github.com/minio/minio-js).
