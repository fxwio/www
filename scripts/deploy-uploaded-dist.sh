#!/bin/sh

set -eu

log() {
  printf '[deploy-upload] %s\n' "$*"
}

die() {
  printf '[deploy-upload] ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

detect_source_dir() {
  extract_dir=$1

  if [ -f "$extract_dir/index.html" ]; then
    printf '%s\n' "$extract_dir"
    return 0
  fi

  if [ -d "$extract_dir/dist" ] && [ -f "$extract_dir/dist/index.html" ]; then
    printf '%s\n' "$extract_dir/dist"
    return 0
  fi

  top_level_count=$(
    find "$extract_dir" -mindepth 1 -maxdepth 1 -type d ! -name '__MACOSX' | wc -l | tr -d ' '
  )

  if [ "$top_level_count" = "1" ]; then
    candidate_dir=$(
      find "$extract_dir" -mindepth 1 -maxdepth 1 -type d ! -name '__MACOSX' | head -n 1
    )

    if [ -n "$candidate_dir" ] && [ -f "$candidate_dir/index.html" ]; then
      printf '%s\n' "$candidate_dir"
      return 0
    fi
  fi

  return 1
}

SITE_ROOT=${SITE_ROOT:-/var/www/ccyaa.cn}
RELEASES_DIR=${RELEASES_DIR:-$SITE_ROOT/releases}
CURRENT_LINK=${CURRENT_LINK:-$SITE_ROOT/current}
ZIP_PATH=${ZIP_PATH:-$RELEASES_DIR/dist.zip}
RELEASE_ID=${RELEASE_ID:-$(date '+%Y%m%d-%H%M%S')}
LOCK_DIR=${LOCK_DIR:-$SITE_ROOT/.deploy-upload-lock}
RUN_NGINX_RELOAD=${RUN_NGINX_RELOAD:-0}
NGINX_RELOAD_CMD=${NGINX_RELOAD_CMD:-systemctl reload nginx}
TMP_DIR=
RELEASE_DIR=$RELEASES_DIR/$RELEASE_ID
ACTIVATED=0

cleanup() {
  exit_code=$?

  if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
    rm -rf -- "$TMP_DIR"
  fi

  if [ "$exit_code" -ne 0 ] && [ "${ACTIVATED:-0}" -eq 0 ] && [ -n "${RELEASE_DIR:-}" ] && [ -d "$RELEASE_DIR" ]; then
    rm -rf -- "$RELEASE_DIR"
  fi

  if [ -n "${LOCK_DIR:-}" ] && [ -d "$LOCK_DIR" ]; then
    rmdir -- "$LOCK_DIR" >/dev/null 2>&1 || true
  fi
}

trap cleanup 0 HUP INT TERM

main() {
  if [ "$#" -gt 1 ]; then
    die "usage: $0 [zip_path]"
  fi

  if [ "$#" -eq 1 ]; then
    ZIP_PATH=$1
  fi

  require_cmd unzip
  require_cmd find
  require_cmd wc
  require_cmd tr
  require_cmd head
  require_cmd cp
  require_cmd ln
  require_cmd mv
  require_cmd rm
  require_cmd date
  require_cmd mkdir
  require_cmd mktemp
  require_cmd sh

  mkdir -p "$SITE_ROOT" "$RELEASES_DIR"

  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    die "another deployment is already running: $LOCK_DIR"
  fi

  if [ ! -f "$ZIP_PATH" ]; then
    die "zip file not found: $ZIP_PATH"
  fi

  if [ -e "$RELEASE_DIR" ]; then
    die "release directory already exists: $RELEASE_DIR"
  fi

  log "site root: $SITE_ROOT"
  log "zip file: $ZIP_PATH"
  log "release id: $RELEASE_ID"

  TMP_DIR=$(mktemp -d "$RELEASES_DIR/.extract-$RELEASE_ID-XXXXXX")
  unzip -q "$ZIP_PATH" -d "$TMP_DIR"

  rm -rf -- "$TMP_DIR/__MACOSX"
  find "$TMP_DIR" -name '.DS_Store' -exec rm -f {} \;

  SOURCE_DIR=$(detect_source_dir "$TMP_DIR") ||
    die "unable to find deployable files in $ZIP_PATH; expected index.html at zip root or under dist/"

  mkdir -p "$RELEASE_DIR"
  cp -R "$SOURCE_DIR"/. "$RELEASE_DIR"/

  if [ ! -f "$RELEASE_DIR/index.html" ]; then
    die "release does not contain index.html after extraction: $RELEASE_DIR"
  fi

  cat >"$RELEASE_DIR/DEPLOY_INFO" <<EOF
release_id=$RELEASE_ID
zip_path=$ZIP_PATH
deployed_at=$(date '+%Y-%m-%dT%H:%M:%S%z')
EOF

  if [ -e "$CURRENT_LINK" ] && [ ! -L "$CURRENT_LINK" ]; then
    current_backup="${CURRENT_LINK}.bak.$(date '+%Y%m%d-%H%M%S')"
    log "current exists as a real directory; moving it to $current_backup"
    mv -- "$CURRENT_LINK" "$current_backup"
  fi

  if [ -L "$CURRENT_LINK" ]; then
    rm -f -- "$CURRENT_LINK"
  fi

  ln -s "$RELEASE_DIR" "$CURRENT_LINK"
  ACTIVATED=1
  log "current -> $RELEASE_DIR"

  if [ "$RUN_NGINX_RELOAD" = "1" ]; then
    log "reloading nginx"
    sh -c "$NGINX_RELOAD_CMD"
  else
    log "skipping nginx reload"
  fi

  rm -f -- "$ZIP_PATH"
  log "deleted $ZIP_PATH"
  log "deployment complete"
}

main "$@"
