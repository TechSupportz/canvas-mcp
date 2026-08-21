# Canvas MCP — agent notes

A loopback HTTP proxy (`mcp_tool_filter.py`) sits in front of `canvas mcp stream` and
exposes only the tools named in `allowed-tools.txt`. Everything else in the repo installs,
runs, or verifies that proxy.

## Invariants

Two independent layers keep this least-privilege. Keep both:

1. The origin starts with `--readonly` (`mcp_tool_filter.py`, `origin_command`).
2. The proxy serves only allowlisted tools — filtered out of `tools/list`, rejected on
   `tools/call` with JSON-RPC `-32601`.

Widening either one is a security change: say so explicitly and ask before doing it.

The proxy is a **transparent pass-through** for everything except those two methods.
Session headers (`Mcp-Session-Id`), SSE streams, chunked bodies, and batch requests all
have to survive unchanged — a batch containing one disallowed `tools/call` is denied
whole, which is deliberate. When editing the proxy, check both response shapes: Canvas
answers `tools/list` as JSON *or* as `text/event-stream`, and `filter_tools_body` handles
each separately.

The listener binds `127.0.0.1` only. The public edge is a Cloudflare Access application
configured by hand in the dashboard; nothing in this repo provisions it, so a change here
cannot be assumed to reach production.

## Secrets

No Canvas token lives in this repo, the unit template, or the rendered unit. Canvas
credentials stay in the Canvas CLI's own config, read only by the origin process. Keep it
that way: no token in a file, a log line, a commit, or a test fixture.

`verify-local.sh` makes a real `canvas_users_me` call. It deliberately discards the
profile body — do not make it print the response.

## Editing rules

`canvas-mcp.service` is generated and untracked. Edit `canvas-mcp.service.in` and re-run
`./install-user-service.sh`; `--render` prints the unit without installing it. Changes to
the template only take effect after a reinstall.

After touching `allowed-tools.txt`, `mcp_tool_filter.py`, or the unit template:

```bash
systemctl --user restart canvas-mcp.service
python3 -m unittest test_mcp_tool_filter.py
./verify-local.sh
```

`verify-local.sh` is the completion bar for a runtime change: every check prints `PASS`,
including the tool count matching the allowlist exactly and the port being loopback-only.
It needs `curl`, `jq`, and `rg`.

`verify-remote-oauth.sh <url>` checks the Cloudflare Access edge instead — it asserts a
`401` and valid OAuth discovery, and never logs in. Run it only when asked; it touches the
public hostname.
