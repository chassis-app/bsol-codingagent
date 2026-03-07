#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: backup_codex.sh [options]

Create a portable backup of Codex configuration.

Options:
  --profile <portable|full|secrets>  Backup profile (default: portable)
  --output <dir>                     Output directory (default: current directory)
  --codex-home <dir>                 Codex home path (default: $CODEX_HOME or $HOME/.codex)
  --encrypt <none|age|gpg>           Optional encryption mode (default: none)
  --age-recipient <recipient>        age recipient (required with --encrypt age)
  --gpg-recipient <recipient>        gpg recipient (required with --encrypt gpg)
  --help                             Show this help

Profiles:
  portable: skills/ (excluding .system), version.json
  full:     portable + sessions/, history.jsonl, state_*.sqlite*, shell_snapshots/, log/
  secrets:  auth.json only
USAGE
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command not found: $1" >&2
    exit 1
  fi
}

PROFILE="portable"
OUTPUT_DIR="$(pwd)"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
ENCRYPT_MODE="none"
AGE_RECIPIENT=""
GPG_RECIPIENT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --codex-home)
      CODEX_HOME="${2:-}"
      shift 2
      ;;
    --encrypt)
      ENCRYPT_MODE="${2:-}"
      shift 2
      ;;
    --age-recipient)
      AGE_RECIPIENT="${2:-}"
      shift 2
      ;;
    --gpg-recipient)
      GPG_RECIPIENT="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

case "$PROFILE" in
  portable|full|secrets) ;;
  *)
    echo "Error: invalid profile '$PROFILE'" >&2
    usage
    exit 1
    ;;
esac

case "$ENCRYPT_MODE" in
  none|age|gpg) ;;
  *)
    echo "Error: invalid encryption mode '$ENCRYPT_MODE'" >&2
    usage
    exit 1
    ;;
esac

require_cmd tar
require_cmd sha256sum
require_cmd hostname
require_cmd date

if [[ "$ENCRYPT_MODE" == "age" ]]; then
  require_cmd age
  if [[ -z "$AGE_RECIPIENT" ]]; then
    echo "Error: --age-recipient is required for --encrypt age" >&2
    exit 1
  fi
fi

if [[ "$ENCRYPT_MODE" == "gpg" ]]; then
  require_cmd gpg
  if [[ -z "$GPG_RECIPIENT" ]]; then
    echo "Error: --gpg-recipient is required for --encrypt gpg" >&2
    exit 1
  fi
fi

if [[ ! -d "$CODEX_HOME" ]]; then
  echo "Error: Codex home directory does not exist: $CODEX_HOME" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BASE_NAME="codex-backup-${PROFILE}-${TIMESTAMP}"
ARCHIVE_PATH="${OUTPUT_DIR}/${BASE_NAME}.tar.gz"
MANIFEST_PATH="${OUTPUT_DIR}/${BASE_NAME}.manifest.json"
SHA_PATH="${OUTPUT_DIR}/${BASE_NAME}.SHA256SUMS"

INCLUDE_PATHS=()
case "$PROFILE" in
  portable)
    INCLUDE_PATHS=(
      "skills"
      "version.json"
    )
    ;;
  full)
    INCLUDE_PATHS=(
      "skills"
      "version.json"
      "sessions"
      "history.jsonl"
      "shell_snapshots"
      "log"
    )
    ;;
  secrets)
    INCLUDE_PATHS=(
      "auth.json"
    )
    ;;
esac

TMP_DIR="$(mktemp -d)"
FILE_LIST="$TMP_DIR/files.txt"
> "$FILE_LIST"
trap 'rm -rf "$TMP_DIR"' EXIT

for rel in "${INCLUDE_PATHS[@]}"; do
  if [[ -e "$CODEX_HOME/$rel" ]]; then
    printf '%s\n' "$rel" >> "$FILE_LIST"
  fi
done

if [[ "$PROFILE" == "full" ]]; then
  while IFS= read -r state_file; do
    printf '%s\n' "$state_file" >> "$FILE_LIST"
  done < <(find "$CODEX_HOME" -maxdepth 1 -type f -name 'state_*.sqlite*' -printf '%f\n' | sort)
fi

sort -u -o "$FILE_LIST" "$FILE_LIST"

FILE_COUNT="$(wc -l < "$FILE_LIST" | tr -d '[:space:]')"
if [[ "$FILE_COUNT" == "0" ]]; then
  echo "Error: no files matched profile '$PROFILE' under $CODEX_HOME" >&2
  exit 1
fi

(
  cd "$CODEX_HOME"
  if grep -qx "skills" "$FILE_LIST"; then
    tar -czf "$ARCHIVE_PATH" \
      --exclude='skills/.system' \
      --exclude='skills/.system/*' \
      --files-from "$FILE_LIST"
  else
    tar -czf "$ARCHIVE_PATH" --files-from "$FILE_LIST"
  fi
)

HOSTNAME_VALUE="$(hostname)"
CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CODEX_VERSION=""
if [[ -f "$CODEX_HOME/version.json" ]]; then
  CODEX_VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CODEX_HOME/version.json" | head -n1)"
fi

{
  printf '{\n'
  printf '  "created_at_utc": "%s",\n' "$(json_escape "$CREATED_AT")"
  printf '  "hostname": "%s",\n' "$(json_escape "$HOSTNAME_VALUE")"
  printf '  "profile": "%s",\n' "$(json_escape "$PROFILE")"
  printf '  "codex_home": "%s",\n' "$(json_escape "$CODEX_HOME")"
  printf '  "codex_version": "%s",\n' "$(json_escape "$CODEX_VERSION")"
  printf '  "archive": "%s",\n' "$(json_escape "$(basename "$ARCHIVE_PATH")")"
  printf '  "file_count": %s,\n' "$FILE_COUNT"
  printf '  "files": [\n'
  i=0
  while IFS= read -r f; do
    i=$((i + 1))
    esc="$(json_escape "$f")"
    if [[ "$i" -lt "$FILE_COUNT" ]]; then
      printf '    "%s",\n' "$esc"
    else
      printf '    "%s"\n' "$esc"
    fi
  done < "$FILE_LIST"
  printf '  ]\n'
  printf '}\n'
} > "$MANIFEST_PATH"

(
  cd "$OUTPUT_DIR"
  sha256sum "$(basename "$ARCHIVE_PATH")" "$(basename "$MANIFEST_PATH")" > "$(basename "$SHA_PATH")"
)

ENCRYPTED_PATH=""
if [[ "$ENCRYPT_MODE" == "age" ]]; then
  ENCRYPTED_PATH="${ARCHIVE_PATH}.age"
  age -r "$AGE_RECIPIENT" -o "$ENCRYPTED_PATH" "$ARCHIVE_PATH"
  (
    cd "$OUTPUT_DIR"
    sha256sum "$(basename "$ENCRYPTED_PATH")" >> "$(basename "$SHA_PATH")"
  )
elif [[ "$ENCRYPT_MODE" == "gpg" ]]; then
  ENCRYPTED_PATH="${ARCHIVE_PATH}.gpg"
  gpg --yes --output "$ENCRYPTED_PATH" --encrypt --recipient "$GPG_RECIPIENT" "$ARCHIVE_PATH"
  (
    cd "$OUTPUT_DIR"
    sha256sum "$(basename "$ENCRYPTED_PATH")" >> "$(basename "$SHA_PATH")"
  )
fi

echo "Backup created: $ARCHIVE_PATH"
echo "Manifest: $MANIFEST_PATH"
echo "Checksums: $SHA_PATH"
if [[ -n "$ENCRYPTED_PATH" ]]; then
  echo "Encrypted archive: $ENCRYPTED_PATH"
fi
