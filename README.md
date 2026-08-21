# canvas-mcp

A thin least-privilege wrapper around [canvas-cli](https://github.com/jjuanrivvera/canvas-cli)'s
MCP server.

All of the actual Canvas work — auth, the API surface, the MCP tools themselves — is
canvas-cli's. This repo adds one thing on top: `canvas mcp stream` exposes a *lot* of
Canvas, and even `--readonly` leaves you with every read tool plus `api get`. If you're
going to reach that server from outside the machine it runs on, you probably want a much
smaller door.

So: a ~250-line Python proxy starts canvas-cli's MCP server on a private loopback port
with `--readonly`, and republishes a filtered view of it on `127.0.0.1:8085`. Only the
tools you list in [`allowed-tools.txt`](allowed-tools.txt) get through. Everything else is
stripped out of discovery and refused if called by name, so a client can't use — or even
see — a tool you didn't choose. Two locks, independently sufficient.

Your Canvas token isn't involved. It stays in canvas-cli's own config, read only by the
origin process; nothing here stores, copies, or logs it.

## Setup

You need Linux with systemd user services, Python 3.10+, and canvas-cli installed,
authenticated (`canvas auth login`), and on `PATH`. The verification script also wants
`curl`, `jq`, and `rg`.

```bash
./install-user-service.sh
./verify-local.sh
```

The installer figures out where the checkout, Python, and canvas-cli live, then writes and
starts a user unit at `~/.config/systemd/user/canvas-mcp.service`. `verify-local.sh` drives
a real MCP handshake against the running server and prints a `PASS` per check — the served
tool list matches the allowlist exactly, a non-allowlisted call is rejected, a harmless read
works, and the port is bound to loopback only.

Then it's an ordinary service:

```bash
systemctl --user status canvas-mcp.service
journalctl --user -u canvas-mcp.service -f
```

To have it start before you log in, an admin runs `loginctl enable-linger <username>`.

<details>
<summary>Or hand it to a coding agent</summary>

Clone the repo, open your agent of choice in it, and paste this:

> Set up this canvas-mcp repo on my machine. Read `AGENTS.md` first — it has the
> invariants you need to respect.
>
> 1. Check the prerequisites: Linux with systemd user services, Python 3.10+, and
>    `canvas` on PATH. Confirm canvas-cli is authenticated by running `canvas users me`
>    — if it fails, stop and tell me to run `canvas auth login` myself, since that is
>    interactive and I need to do it.
> 2. Run `python3 -m unittest test_mcp_tool_filter.py`, then `./install-user-service.sh`,
>    then `./verify-local.sh`. Every check must print PASS. If something fails, diagnose
>    it with `journalctl --user -u canvas-mcp.service` and fix it before continuing.
> 3. Show me the tool names in `allowed-tools.txt` and ask whether I want to change the
>    list before we finish. If I do, edit it, restart the service, and re-run
>    `./verify-local.sh`.
>
> Do not put my Canvas token anywhere — not in a file, a log, or a commit; canvas-cli
> already holds it. Do not remove the `--readonly` flag or widen the allowlist without
> asking me first. Do not commit anything.

Publishing it remotely involves clicking around a Cloudflare dashboard, so that part
stays manual — see below.

</details>

## Picking the tools

`allowed-tools.txt` is the entire policy — one exact MCP tool name per line, `#` for
comments. The 13 in there now cover a coursework workflow: who am I, courses, assignments,
planner items, todos, calendar, submissions, announcements. Change the list, restart, and
re-run `verify-local.sh`; it fails loudly if what's being served has drifted from what you
asked for.

`canvas mcp tools --readonly` writes the full set of available tools to `mcp-tools.json`
if you want to browse what else you could add.

## Configuration

`NAME=value` lines in `~/.config/canvas-mcp/environment`, then restart. The same variables
apply if you run `./run-server.sh` directly.

| Variable | Default | Purpose |
| --- | --- | --- |
| `CANVAS_MCP_HOST` | `127.0.0.1` | Filter listen address |
| `CANVAS_MCP_PORT` | `8085` | Filter listen port |
| `CANVAS_MCP_ORIGIN_PORT` | `8086` | Private canvas-cli origin port |
| `CANVAS_MCP_ALLOWLIST` | `./allowed-tools.txt` | Allowlist path |
| `CANVAS_MCP_LOG_LEVEL` | `info` | Log level |
| `PYTHON_BIN` / `CANVAS_BIN` | found on `PATH` | Executable overrides |

## Using it

Locally, point any Streamable HTTP MCP client at `http://127.0.0.1:8085/mcp`:

```json
{ "mcpServers": { "canvas": { "type": "http", "url": "http://127.0.0.1:8085/mcp" } } }
```

**Remotely** — port 8085 has no authentication of its own, by design. Put an
authenticating proxy in front of it and never expose it directly. A Cloudflare Tunnel with
an Access policy in front works well: create the Access application *before* the hostname
exists, restrict it to your own email, and enable Managed OAuth with dynamic client
registration plus localhost/loopback callbacks so CLI clients can complete the login. Then
map the hostname to `http://127.0.0.1:8085`.

`./verify-remote-oauth.sh https://your-host/mcp` checks that edge is actually doing its
job: unauthenticated requests get a `401`, and OAuth discovery advertises registration, the
authorization code grant, public clients, and PKCE `S256`.

Once it's published, clients connect the usual way:

```bash
codex mcp add canvas --url https://your-host/mcp && codex mcp login canvas
claude mcp add --transport http --scope user canvas https://your-host/mcp
```

## Credits

canvas-cli by [@jjuanrivvera](https://github.com/jjuanrivvera/canvas-cli) does the heavy
lifting. This repo is just a gate in front of it.
