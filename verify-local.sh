#!/usr/bin/env bash
set -euo pipefail

MCP_URL="${MCP_URL:-http://127.0.0.1:8085/mcp}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MCP_PORT="${MCP_URL%/mcp}"
MCP_PORT="${MCP_PORT##*:}"
VERIFY_DIR="$(mktemp -d /tmp/canvas-mcp-verify.XXXXXX)"
trap 'rm -rf -- "$VERIFY_DIR"' EXIT

post_mcp() {
  local request_json="$1"
  local output_file="$2"
  shift 2
  curl --silent --show-error --fail-with-body \
    --request POST "$MCP_URL" \
    --header 'Content-Type: application/json' \
    --header 'Accept: application/json, text/event-stream' \
    "$@" \
    --data "$request_json" \
    --output "$output_file"
}

extract_sse_json() {
  case "$(head -c 1 "$1")" in
    '{'|'[') jq . "$1" ;;
    *) sed -n 's/^data:[[:space:]]*//p' "$1" | jq -s '.[0]' ;;
  esac
}

curl --silent --show-error --max-time 2 "$MCP_URL" --output /dev/null || true

post_mcp \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"canvas-mcp-local-verifier","version":"1.0.0"}}}' \
  "$VERIFY_DIR/initialize.body" \
  --dump-header "$VERIFY_DIR/initialize.headers"

tr -d '\r' < "$VERIFY_DIR/initialize.headers" > "$VERIFY_DIR/initialize.headers.clean"
MCP_SESSION_ID="$(sed -n 's/^[Mm][Cc][Pp]-[Ss]ession-[Ii]d:[[:space:]]*//p' "$VERIFY_DIR/initialize.headers.clean" | head -n 1)"
if [[ -z "$MCP_SESSION_ID" ]]; then
  echo 'FAIL: initialize did not return Mcp-Session-Id' >&2
  exit 1
fi

extract_sse_json "$VERIFY_DIR/initialize.body" > "$VERIFY_DIR/initialize.json"
jq -e '.result.serverInfo.name == "canvas" and (.result.protocolVersion | length > 0)' \
  "$VERIFY_DIR/initialize.json" >/dev/null
SERVER_VERSION="$(jq -r '.result.serverInfo.version' "$VERIFY_DIR/initialize.json")"
echo "PASS: MCP initialize (Canvas ${SERVER_VERSION})"

post_mcp \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  "$VERIFY_DIR/initialized.body" \
  --header "Mcp-Session-Id: $MCP_SESSION_ID"

post_mcp \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  "$VERIFY_DIR/tools.body" \
  --header "Mcp-Session-Id: $MCP_SESSION_ID"
extract_sse_json "$VERIFY_DIR/tools.body" > "$VERIFY_DIR/tools.json"
EXPECTED_TOOLS="$VERIFY_DIR/expected-tools.txt"
rg -v '^[[:space:]]*(#|$)' "$SCRIPT_DIR/allowed-tools.txt" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort > "$EXPECTED_TOOLS"
jq -e --argjson count "$(wc -l < "$EXPECTED_TOOLS")" '.result.tools | type == "array" and length == $count' "$VERIFY_DIR/tools.json" >/dev/null
jq -e '.result.tools | any(.name == "canvas_users_me")' "$VERIFY_DIR/tools.json" >/dev/null
jq -r '.result.tools[].name' "$VERIFY_DIR/tools.json" | sort > "$VERIFY_DIR/actual-tools.txt"
cmp --silent "$EXPECTED_TOOLS" "$VERIFY_DIR/actual-tools.txt"
TOOL_COUNT="$(jq -r '.result.tools | length' "$VERIFY_DIR/tools.json")"
echo "PASS: tool discovery (${TOOL_COUNT} tools; canvas_users_me present)"

post_mcp \
  '{"jsonrpc":"2.0","id":99,"method":"tools/call","params":{"name":"canvas_accounts_list","arguments":{}}}' \
  "$VERIFY_DIR/denied-tool.body" \
  --header "Mcp-Session-Id: $MCP_SESSION_ID"
extract_sse_json "$VERIFY_DIR/denied-tool.body" > "$VERIFY_DIR/denied-tool.json"
jq -e '.error.code == -32601' "$VERIFY_DIR/denied-tool.json" >/dev/null
echo 'PASS: non-allowlisted tool call rejected'

# Harmless, read-only Canvas request. The returned profile is never printed.
post_mcp \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"canvas_users_me","arguments":{"flags":{"output":"json","quiet":true}}}}' \
  "$VERIFY_DIR/tool-call.body" \
  --header "Mcp-Session-Id: $MCP_SESSION_ID"
extract_sse_json "$VERIFY_DIR/tool-call.body" > "$VERIFY_DIR/tool-call.json"
jq -e '.result != null and .error == null and ((.result.isError // false) == false)' \
  "$VERIFY_DIR/tool-call.json" >/dev/null
echo 'PASS: harmless Canvas users/me read request'

if ss -ltnH "sport = :${MCP_PORT}" | awk '{print $4}' | rg -q "^(127\\.0\\.0\\.1|\\[::1\\]):${MCP_PORT}$"; then
  echo "PASS: port ${MCP_PORT} is listening only on loopback"
else
  echo "FAIL: port ${MCP_PORT} is absent or is not loopback-only" >&2
  ss -ltnH "sport = :${MCP_PORT}" >&2 || true
  exit 1
fi
