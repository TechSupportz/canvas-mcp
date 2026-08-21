#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
CANVAS_BIN="${CANVAS_BIN:-$(command -v canvas || true)}"

if [[ -z "$PYTHON_BIN" ]]; then
  echo 'error: python3 was not found in PATH; set PYTHON_BIN to its absolute path' >&2
  exit 1
fi
if [[ -z "$CANVAS_BIN" ]]; then
  echo 'error: canvas was not found in PATH; set CANVAS_BIN to its absolute path' >&2
  exit 1
fi

exec "$PYTHON_BIN" "$PROJECT_DIR/mcp_tool_filter.py" \
  --host "${CANVAS_MCP_HOST:-127.0.0.1}" \
  --port "${CANVAS_MCP_PORT:-8085}" \
  --origin-port "${CANVAS_MCP_ORIGIN_PORT:-8086}" \
  --allowlist "${CANVAS_MCP_ALLOWLIST:-$PROJECT_DIR/allowed-tools.txt}" \
  --canvas "$CANVAS_BIN" \
  --log-level "${CANVAS_MCP_LOG_LEVEL:-info}"
