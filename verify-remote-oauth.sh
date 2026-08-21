#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 https://canvas-mcp.<domain>/mcp" >&2
  exit 2
fi

MCP_URL="$1"
case "$MCP_URL" in
  https://*/mcp) ;;
  *) echo 'FAIL: expected an HTTPS URL ending in /mcp' >&2; exit 2 ;;
esac

VERIFY_DIR="$(mktemp -d /tmp/canvas-mcp-oauth-verify.XXXXXX)"
trap 'rm -rf -- "$VERIFY_DIR"' EXIT

HTTP_STATUS="$(curl --silent --show-error \
  --request POST "$MCP_URL" \
  --header 'Content-Type: application/json' \
  --header 'Accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"canvas-mcp-oauth-verifier","version":"1.0.0"}}}' \
  --dump-header "$VERIFY_DIR/headers" \
  --output "$VERIFY_DIR/body" \
  --write-out '%{http_code}')"

if [[ "$HTTP_STATUS" != '401' ]]; then
  echo "FAIL: unauthenticated endpoint returned HTTP ${HTTP_STATUS}, expected 401" >&2
  exit 1
fi
echo 'PASS: unauthenticated MCP request rejected with HTTP 401'

tr -d '\r' < "$VERIFY_DIR/headers" > "$VERIFY_DIR/headers.clean"
WWW_AUTHENTICATE="$(sed -n 's/^[Ww][Ww][Ww]-[Aa]uthenticate:[[:space:]]*//p' "$VERIFY_DIR/headers.clean" | head -n 1)"
RESOURCE_METADATA="$(printf '%s\n' "$WWW_AUTHENTICATE" | sed -n 's/.*resource_metadata="\([^"]*\)".*/\1/p')"
if [[ -z "$RESOURCE_METADATA" ]]; then
  echo 'FAIL: WWW-Authenticate does not advertise resource_metadata' >&2
  exit 1
fi
echo 'PASS: WWW-Authenticate advertises OAuth protected-resource metadata'

curl --silent --show-error --fail "$RESOURCE_METADATA" --output "$VERIFY_DIR/resource.json"
jq -e '.resource and (.authorization_servers | type == "array" and length > 0)' \
  "$VERIFY_DIR/resource.json" >/dev/null
AUTHORIZATION_SERVER="$(jq -r '.authorization_servers[0]' "$VERIFY_DIR/resource.json")"
echo 'PASS: protected-resource discovery returned an authorization server'

curl --silent --show-error --fail \
  "${AUTHORIZATION_SERVER%/}/.well-known/oauth-authorization-server" \
  --output "$VERIFY_DIR/authorization-server.json"

jq -e '
  .authorization_endpoint and
  .token_endpoint and
  .registration_endpoint and
  (.grant_types_supported | index("authorization_code")) != null and
  (.code_challenge_methods_supported | index("S256")) != null and
  (.token_endpoint_auth_methods_supported | index("none")) != null
' "$VERIFY_DIR/authorization-server.json" >/dev/null

echo 'PASS: authorization-server discovery advertises DCR, authorization code, public clients, and PKCE S256'
echo 'NEXT: use Codex/another MCP client to complete browser login and verify authorized MCP initialize/tools.'
