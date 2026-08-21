#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$PROJECT_DIR/canvas-mcp.service.in"
SERVICE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE_FILE="$SERVICE_DIR/canvas-mcp.service"
ENVIRONMENT_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/canvas-mcp/environment"
MODE=install

if [[ $# -gt 1 ]] || { [[ $# -eq 1 ]] && [[ "$1" != '--render' ]]; }; then
  echo "usage: $0 [--render]" >&2
  exit 2
fi
if [[ ${1:-} == '--render' ]]; then
  MODE=render
fi

if [[ "$MODE" == install ]]; then
  for command_name in python3 canvas systemctl; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      echo "error: required command not found in PATH: $command_name" >&2
      exit 1
    fi
  done
fi

escape_systemd_path() {
  local input="$1" character output='' index
  for ((index = 0; index < ${#input}; index++)); do
    character="${input:index:1}"
    case "$character" in
      ' ') output+='\x20' ;;
      $'\t') output+='\x09' ;;
      $'\n'|$'\r')
        echo 'error: the checkout path cannot contain a newline' >&2
        return 1
        ;;
      '\\') output+='\x5c' ;;
      '"') output+='\x22' ;;
      '%') output+='%%' ;;
      *) output+="$character" ;;
    esac
  done
  printf '%s' "$output"
}

# First encode the path for systemd, then escape sed replacement characters.
UNIT_PROJECT_DIR="$(escape_systemd_path "$PROJECT_DIR")"
ESCAPED_PROJECT_DIR="$(printf '%s' "$UNIT_PROJECT_DIR" | sed -e 's/[\\&|]/\\&/g')"
UNIT_ENVIRONMENT_FILE="$(escape_systemd_path "$ENVIRONMENT_FILE")"
ESCAPED_ENVIRONMENT_FILE="$(printf '%s' "$UNIT_ENVIRONMENT_FILE" | sed -e 's/[\\&|]/\\&/g')"
TEMP_SERVICE="$(mktemp "${TMPDIR:-/tmp}/canvas-mcp.service.XXXXXX")"
trap 'rm -f -- "$TEMP_SERVICE"' EXIT
sed \
  -e "s|@PROJECT_DIR@|$ESCAPED_PROJECT_DIR|g" \
  -e "s|@ENVIRONMENT_FILE@|$ESCAPED_ENVIRONMENT_FILE|g" \
  "$TEMPLATE" > "$TEMP_SERVICE"

if [[ "$MODE" == render ]]; then
  cat "$TEMP_SERVICE"
  exit 0
fi

mkdir -p -- "$SERVICE_DIR"
if [[ -L "$SERVICE_FILE" ]]; then
  unlink "$SERVICE_FILE"
fi
install -m 0644 "$TEMP_SERVICE" "$SERVICE_FILE"

systemctl --user daemon-reload
systemctl --user enable --now canvas-mcp.service
systemctl --user restart canvas-mcp.service

echo "Installed and started $SERVICE_FILE"
echo "Project directory: $PROJECT_DIR"
