#!/usr/bin/env bash

set -Eeuo pipefail

log() {
  printf '[deploy] %s\n' "$*"
}

die() {
  printf '[deploy] ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

prune_old_releases() {
  local releases_dir="$1"
  local keep_releases="$2"
  local current_target="${3:-}"

  [[ "$keep_releases" =~ ^[0-9]+$ ]] || die "KEEP_RELEASES must be an integer"

  if (( keep_releases <= 0 )); then
    log "skipping release pruning"
    return
  fi

  mapfile -t release_paths < <(
    find "$releases_dir" -mindepth 1 -maxdepth 1 -type d | sort
  )

  local release_count="${#release_paths[@]}"

  if (( release_count <= keep_releases )); then
    return
  fi

  local prune_count=$((release_count - keep_releases))
  local index

  for ((index = 0; index < prune_count; index++)); do
    if [[ -n "$current_target" ]] &&
      [[ "$(resolve_dir "${release_paths[index]}")" == "$current_target" ]]; then
      log "skipping active release during pruning: ${release_paths[index]}"
      continue
    fi

    log "removing old release: ${release_paths[index]}"
    rm -rf -- "${release_paths[index]}"
  done
}

resolve_dir() {
  (
    cd -- "$1" >/dev/null 2>&1 &&
      pwd -P
  )
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"

cd "$REPO_DIR"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  die "REPO_DIR is not a git repository: $REPO_DIR"

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-${CURRENT_BRANCH:-main}}"
SITE_ROOT="${SITE_ROOT:-/var/www/ccyaa.cn}"
RELEASES_DIR="${RELEASES_DIR:-$SITE_ROOT/releases}"
CURRENT_LINK="${CURRENT_LINK:-$SITE_ROOT/current}"
KEEP_RELEASES="${KEEP_RELEASES:-5}"
RUN_NGINX_RELOAD="${RUN_NGINX_RELOAD:-1}"
NPM_CMD="${NPM_CMD:-npm}"
BUILD_CMD="${BUILD_CMD:-npm run build}"
NGINX_RELOAD_CMD="${NGINX_RELOAD_CMD:-sudo systemctl reload nginx}"
LOCK_DIR="${LOCK_DIR:-$SITE_ROOT/.deploy-lock}"

trap 'cleanup' EXIT

cleanup() {
  if [[ -d "$LOCK_DIR" ]]; then
    rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
  fi
}

mkdir -p "$SITE_ROOT" "$RELEASES_DIR"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  die "another deployment is already running: $LOCK_DIR"
fi

require_cmd git
require_cmd "$NPM_CMD"
require_cmd rsync
require_cmd find
require_cmd date

log "repo: $REPO_DIR"
log "branch: $DEPLOY_BRANCH"
log "site root: $SITE_ROOT"

if ! git diff --quiet --ignore-submodules --; then
  die "working tree has local changes; commit/stash them before deploying"
fi

if ! git diff --cached --quiet --ignore-submodules --; then
  die "index has staged changes; commit/stash them before deploying"
fi

log "fetching latest code from origin/$DEPLOY_BRANCH"
git fetch --prune origin "$DEPLOY_BRANCH"
git checkout "$DEPLOY_BRANCH"
git pull --ff-only origin "$DEPLOY_BRANCH"

if [[ -f package-lock.json ]]; then
  log "installing dependencies with npm ci"
  "$NPM_CMD" ci
else
  log "package-lock.json not found; installing dependencies with npm install"
  "$NPM_CMD" install
fi

log "building site"
eval "$BUILD_CMD"

[[ -d dist ]] || die "build output not found: $REPO_DIR/dist"

RELEASE_ID="${RELEASE_ID:-$(date '+%Y%m%d-%H%M%S')}"
RELEASE_DIR="$RELEASES_DIR/$RELEASE_ID"
COMMIT_SHA="$(git rev-parse HEAD)"

if [[ -e "$RELEASE_DIR" ]]; then
  die "release directory already exists: $RELEASE_DIR"
fi

mkdir -p "$RELEASE_DIR"

log "syncing dist/ to $RELEASE_DIR"
rsync -a --delete dist/ "$RELEASE_DIR/"

cat >"$RELEASE_DIR/DEPLOY_INFO" <<EOF
release_id=$RELEASE_ID
branch=$DEPLOY_BRANCH
commit_sha=$COMMIT_SHA
deployed_at=$(date '+%Y-%m-%dT%H:%M:%S%z')
repo_dir=$REPO_DIR
EOF

ln -sfn "$RELEASE_DIR" "$CURRENT_LINK"
log "switched current release to $RELEASE_DIR"

if [[ "$RUN_NGINX_RELOAD" == "1" ]]; then
  log "reloading nginx"
  eval "$NGINX_RELOAD_CMD"
else
  log "skipping nginx reload"
fi

prune_old_releases "$RELEASES_DIR" "$KEEP_RELEASES" "$(resolve_dir "$CURRENT_LINK" || true)"

log "deployment complete"
log "current release: $RELEASE_DIR"
log "commit: $COMMIT_SHA"
