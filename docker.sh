#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROLE=storage
SERVICE=minio
ENV_FILE="$SCRIPT_DIR/.env"
ACTION=up
ACTION_SET=false
FOLLOW=false
TAIL=100
WAIT_TIMEOUT=120
ADMIN=false
PULL=false
BUILD=true
PROJECT_NAME=""
BACKUP_FILE=""

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<EOF
Usage: ./docker.sh [action] [options]
Actions (choose one; default: --up):
  --up             Create the shared network and start healthy $SERVICE
  --init-env       Copy .env.example without overwriting an existing file
  --down           Remove containers; keep persistent data and external network
  --stop           Stop containers
  --restart        Restart containers
  --status         Show container status and health
  --logs           Show logs (--follow and --tail N supported)
  --config         Validate Compose without printing environment values
  --init-bucket    Ensure MinIO is healthy, then create its private bucket
Options:
  --env-file PATH  Select an env file (relative to the caller's directory)
  --project-name NAME  Override the Compose project name
  --wait-timeout N Wait up to N seconds for health (default: 120)
  --pull           Refresh base images when building before --up
  --no-build       Use already built MinIO/client images
  --follow         Follow --logs continuously
  --tail N         Log lines per container (default: 100)
  --help           Show this help
EOF
}
set_action() {
  "$ACTION_SET" && fail "Choose only one action."
  ACTION="$1"; ACTION_SET=true
}
value_required() {
  [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || fail "$1 requires a value."
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --up) set_action up ;;
    --init-env) set_action init-env ;;
    --down) set_action down ;;
    --stop) set_action stop ;;
    --restart) set_action restart ;;
    --status) set_action status ;;
    --logs) set_action logs ;;
    --config) set_action config ;;
    --init-bucket)
      [[ "$ROLE" == storage ]] || fail "--init-bucket is only available in storage/docker.sh."
      set_action init-bucket ;;
    --backup)
      [[ "$ROLE" == database ]] || fail "--backup is only available in database/docker.sh."
      value_required "$@"; set_action backup; BACKUP_FILE="$2"; shift ;;
    --admin)
      [[ "$ROLE" == database ]] || fail "--admin is only available in database/docker.sh."
      ADMIN=true ;;
    --env-file) value_required "$@"; ENV_FILE="$2"; shift ;;
    --project-name) value_required "$@"; PROJECT_NAME="$2"; shift ;;
    --wait-timeout)
      value_required "$@"
      [[ "$2" =~ ^[1-9][0-9]*$ ]] || fail "--wait-timeout must be a positive integer."
      WAIT_TIMEOUT="$2"; shift ;;
    --tail)
      value_required "$@"
      [[ "$2" =~ ^[0-9]+$ ]] || fail "--tail must be a non-negative integer."
      TAIL="$2"; shift ;;
    --follow|-f) FOLLOW=true ;;
    --pull) PULL=true ;;
    --no-build) BUILD=false ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unknown option: $1. Use --help." ;;
  esac
  shift
done
"$FOLLOW" && [[ "$ACTION" != logs ]] && fail "--follow requires --logs."
"$PULL" && [[ "$ACTION" != up ]] && fail "--pull requires --up."
! "$BUILD" && [[ "$ACTION" != up && "$ACTION" != init-bucket ]] && fail "--no-build requires --up or --init-bucket."
"$PULL" && ! "$BUILD" && fail "--pull cannot be combined with --no-build."
[[ "$ENV_FILE" == /* ]] || ENV_FILE="$PWD/$ENV_FILE"
if [[ -n "$BACKUP_FILE" && "$BACKUP_FILE" != /* ]]; then BACKUP_FILE="$PWD/$BACKUP_FILE"; fi

if [[ "$ACTION" == init-env ]]; then
  [[ ! -e "$ENV_FILE" ]] || fail "$ENV_FILE already exists; it was not overwritten."
  (set -o noclobber; umask 077; cat "$SCRIPT_DIR/.env.example" > "$ENV_FILE")
  printf 'Created %s. Fill its credentials before running --up.\n' "$ENV_FILE"
  exit 0
fi
[[ -f "$ENV_FILE" ]] || fail "Missing $ENV_FILE. Run --init-env and fill its credentials."
command -v docker >/dev/null 2>&1 || fail "Docker is not installed."
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required."
cd "$SCRIPT_DIR"
COMPOSE=(docker compose --env-file "$ENV_FILE" -f "$SCRIPT_DIR/docker-compose.yml")
[[ -z "$PROJECT_NAME" ]] || COMPOSE+=(--project-name "$PROJECT_NAME")
"$ADMIN" && COMPOSE+=(--profile admin)
compose() { "${COMPOSE[@]}" "$@"; }
compose config --quiet
if [[ "$ACTION" == config ]]; then
  printf 'Production %s Compose configuration is valid.\n' "$ROLE"
  exit 0
fi
docker info >/dev/null 2>&1 || fail "Cannot access the Docker daemon."
ensure_network() {
  local network_name
  network_name="$(compose config --environment | sed -n 's/^BACKEND_NETWORK=//p')"
  network_name="${network_name:-magnificat-backend}"
  if ! docker network inspect "$network_name" >/dev/null 2>&1; then
    docker network create --driver bridge "$network_name"
  fi
}
start_service() {
  ensure_network
  local services=("$SERVICE")
  if "$ADMIN"; then
    # Validate before creating containers without exposing the password.
    [[ -n "$(compose config --environment | sed -n 's/^PGADMIN_DEFAULT_PASSWORD=//p')" ]] ||
      fail "Set PGADMIN_DEFAULT_PASSWORD before enabling --admin."
    services+=(pgadmin)
  fi
  if "$BUILD"; then
    local build_options=()
    "$PULL" && build_options+=(--pull)
    compose --profile tools build "${build_options[@]}" minio init-bucket
  fi
  compose up --detach --wait --wait-timeout "$WAIT_TIMEOUT" "${services[@]}"
}
init_bucket() {
  compose --profile tools run --rm --no-deps init-bucket
}
case "$ACTION" in
  up)
    start_service
    [[ "$ROLE" != storage ]] || init_bucket
    compose ps ;;
  init-bucket) start_service; init_bucket ;;
  down) compose down ;;
  stop) compose stop ;;
  restart) compose restart ;;
  status) compose ps ;;
  logs)
    options=(--tail "$TAIL")
    "$FOLLOW" && options+=(--follow)
    exec "${COMPOSE[@]}" logs "${options[@]}" ;;
  backup)
    [[ ! -e "$BACKUP_FILE" && ! -e "$BACKUP_FILE.partial" ]] || fail "Backup target already exists."
    (set -o noclobber; umask 077
      compose exec -T postgres sh -ec 'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-privileges' > "$BACKUP_FILE.partial")
    mv -- "$BACKUP_FILE.partial" "$BACKUP_FILE"
    printf 'Database backup saved to %s\n' "$BACKUP_FILE" ;;
esac
