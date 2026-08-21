# Canvas remote MCP on relic-01

Canvas CLI 1.13.0 runs as the existing authenticated Linux user `tnitish` and
serves Streamable HTTP MCP only on `127.0.0.1:8085`. The existing dashboard-
managed Cloudflare Tunnel should publish that loopback origin. A Cloudflare
Access self-hosted application with Managed OAuth enforces identity policy and
provides MCP-compatible OAuth discovery, DCR, authorization code + PKCE, access
tokens, and refresh tokens.

No Canvas token is stored in this directory or in the systemd unit.

## Local service

The installed user service is linked from:

```text
~/.config/systemd/user/canvas-mcp.service
```

Useful commands:

```bash
systemctl --user status canvas-mcp.service
journalctl --user -u canvas-mcp.service
~/srv/canvas-mcp/verify-local.sh
~/srv/canvas-mcp/verify-remote-oauth.sh https://canvas-mcp.<domain>/mcp
```

User lingering is enabled for `tnitish`, so the enabled user service starts at
boot without an interactive login.

The public MCP surface is restricted to the 13 read-only Canvas tools in
[`allowed-tools.txt`](allowed-tools.txt), selected for the Notion coursework
workflow. The local filter removes every other tool from discovery and rejects
direct calls to non-allowlisted tools. It starts the Canvas CLI with `--readonly`
on the private loopback port `8086`, then serves the filtered endpoint on `8085`.

After editing the allowlist, restart the service and run `verify-local.sh`.
Keep the upstream `--readonly` flag in `mcp_tool_filter.py` unless write access is
explicitly required; the allowlist is an additional least-privilege layer.

## Manual Cloudflare dashboard configuration

Create the Access application before publishing the tunnel hostname, so there
is no interval in which the raw MCP endpoint is public. Create a **Self-hosted**
Access application for `canvas-mcp.<domain>/*` (not a service-token policy and
not generic HTTP Basic authentication):

1. Add one `Allow` policy with `Include -> Emails -> <MY_EMAIL>`.
2. Do not add a broad `Everyone` or `Service Auth` allow rule.
3. Under **Advanced settings**, enable **Managed OAuth**.
4. Enable dynamic client registration.
5. Enable both **Allow localhost clients** and **Allow loopback clients** so
   desktop/CLI MCP clients can receive their OAuth callback.
6. Use a 5-15 minute access-token lifetime and a 1-2 week grant/session
   duration.
7. Save the application, then confirm its policy covers the hostname before
   publishing the hostname.

Do not create or alter the tunnel itself. After the Access application exists,
edit the existing tunnel in the dashboard and add this public hostname mapping:

```text
Hostname: canvas-mcp.<domain>
Service type: HTTP
Origin URL: http://127.0.0.1:8085
```

Expected remote URL:

```text
https://canvas-mcp.<domain>/mcp
```

Unauthenticated requests should return `401` with a `WWW-Authenticate: Bearer`
challenge containing a `resource_metadata` URL. Follow that URL and the listed
authorization server metadata to confirm a registration endpoint, authorization
code grant, public-client token auth (`none`), and PKCE `S256`.

## Clients

Codex:

```bash
codex mcp add canvas --url https://canvas-mcp.<domain>/mcp
codex mcp login canvas
```

Claude Code:

```bash
claude mcp add --transport http --scope user canvas https://canvas-mcp.<domain>/mcp
# Then open Claude Code, run /mcp, and complete the browser login.
```

Generic Streamable HTTP MCP configuration:

```json
{
  "mcpServers": {
    "canvas": {
      "type": "http",
      "url": "https://canvas-mcp.<domain>/mcp"
    }
  }
}
```

The client stores Cloudflare OAuth access/refresh tokens locally. Canvas API
credentials remain under `/home/tnitish/.canvas-cli` on relic-01 and are used
only by the origin process.
