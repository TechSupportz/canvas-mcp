#!/usr/bin/env python3
"""Run Canvas MCP behind an exact tool allowlist.

The proxy filters tools/list responses and rejects tools/call requests for tools
that are not advertised. All other MCP traffic, including session headers and
long-lived SSE requests, is passed through unchanged.
"""

from __future__ import annotations

import argparse
import http.client
import json
from pathlib import Path
import signal
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}


def load_allowlist(path: Path) -> frozenset[str]:
    tools = {
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }
    if not tools:
        raise ValueError(f"tool allowlist is empty: {path}")
    return frozenset(tools)


def request_method(payload: Any) -> str | None:
    return payload.get("method") if isinstance(payload, dict) else None


def requested_tool(payload: Any) -> str | None:
    if request_method(payload) != "tools/call":
        return None
    params = payload.get("params")
    return params.get("name") if isinstance(params, dict) else None


def disallowed_tool_call(
    payload: Any, allowed_tools: frozenset[str]
) -> tuple[dict[str, Any], str | None] | None:
    requests = payload if isinstance(payload, list) else [payload]
    for request in requests:
        if isinstance(request, dict) and request_method(request) == "tools/call":
            tool_name = requested_tool(request)
            if tool_name not in allowed_tools:
                return request, tool_name
    return None


def filter_tool_result(payload: Any, allowed_tools: frozenset[str]) -> Any:
    """Filter a JSON-RPC tools/list result without changing other responses."""
    if not isinstance(payload, dict):
        return payload
    result = payload.get("result")
    if not isinstance(result, dict) or not isinstance(result.get("tools"), list):
        return payload
    result["tools"] = [
        tool
        for tool in result["tools"]
        if isinstance(tool, dict) and tool.get("name") in allowed_tools
    ]
    return payload


def filter_tools_body(body: bytes, content_type: str, allowed_tools: frozenset[str]) -> bytes:
    """Filter either a JSON response or JSON payloads in an SSE response."""
    if "text/event-stream" not in content_type.lower():
        payload = json.loads(body)
        return json.dumps(filter_tool_result(payload, allowed_tools), separators=(",", ":")).encode()

    output: list[bytes] = []
    for line in body.splitlines(keepends=True):
        stripped = line.rstrip(b"\r\n")
        ending = line[len(stripped) :]
        if stripped.startswith(b"data:"):
            prefix, data = stripped.split(b":", 1)
            whitespace = data[: len(data) - len(data.lstrip())]
            payload = json.loads(data.lstrip())
            filtered = json.dumps(
                filter_tool_result(payload, allowed_tools), separators=(",", ":")
            ).encode()
            line = prefix + b":" + whitespace + filtered + ending
        output.append(line)
    return b"".join(output)


def rpc_tool_denied(payload: dict[str, Any], tool_name: str | None) -> bytes:
    name = tool_name if isinstance(tool_name, str) else "<missing>"
    response = {
        "jsonrpc": "2.0",
        "id": payload.get("id"),
        "error": {
            "code": -32601,
            "message": f"Tool is not exposed by this MCP server: {name}",
        },
    }
    return json.dumps(response, separators=(",", ":")).encode()


class ToolFilterHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "CanvasMCPToolFilter/1.0"

    @property
    def filter_server(self) -> "ToolFilterServer":
        return self.server  # type: ignore[return-value]

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("tool-filter: " + fmt % args + "\n")

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0"))
        return self.rfile.read(length) if length else b""

    def _send_bytes(self, status: int, content_type: str, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _proxy(self) -> None:
        body = self._read_body()
        payload: Any = None
        is_tools_list = False
        if body and "application/json" in self.headers.get("Content-Type", "application/json"):
            try:
                payload = json.loads(body)
                is_tools_list = request_method(payload) == "tools/list"
            except json.JSONDecodeError:
                pass

        denied = disallowed_tool_call(payload, self.filter_server.allowed_tools)
        if denied is not None:
            denied_request, tool_name = denied
            self._send_bytes(
                200, "application/json", rpc_tool_denied(denied_request, tool_name)
            )
            return

        headers = {
            key: value
            for key, value in self.headers.items()
            if key.lower() not in HOP_BY_HOP_HEADERS and key.lower() != "host"
        }
        headers["Host"] = f"{self.filter_server.upstream_host}:{self.filter_server.upstream_port}"

        connection = http.client.HTTPConnection(
            self.filter_server.upstream_host, self.filter_server.upstream_port, timeout=300
        )
        try:
            connection.request(self.command, self.path, body=body or None, headers=headers)
            response = connection.getresponse()
            content_type = response.getheader("Content-Type", "application/octet-stream")

            if is_tools_list:
                filtered_body = filter_tools_body(
                    response.read(), content_type, self.filter_server.allowed_tools
                )
                self.send_response(response.status, response.reason)
                for key, value in response.getheaders():
                    if key.lower() not in HOP_BY_HOP_HEADERS | {"content-length"}:
                        self.send_header(key, value)
                self.send_header("Content-Length", str(len(filtered_body)))
                self.end_headers()
                self.wfile.write(filtered_body)
                return

            self.send_response(response.status, response.reason)
            response_length = response.getheader("Content-Length")
            for key, value in response.getheaders():
                if key.lower() not in HOP_BY_HOP_HEADERS:
                    self.send_header(key, value)
            use_chunks = response_length is None and self.command != "HEAD"
            if use_chunks:
                self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()

            if self.command != "HEAD":
                while chunk := response.read(64 * 1024):
                    if use_chunks:
                        self.wfile.write(f"{len(chunk):X}\r\n".encode() + chunk + b"\r\n")
                    else:
                        self.wfile.write(chunk)
                    self.wfile.flush()
                if use_chunks:
                    self.wfile.write(b"0\r\n\r\n")
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as exc:
            self.log_error("upstream request failed: %s", exc)
            if not self.wfile.closed:
                self.close_connection = True
        finally:
            connection.close()

    do_GET = _proxy
    do_POST = _proxy
    do_DELETE = _proxy
    do_OPTIONS = _proxy
    do_HEAD = _proxy


class ToolFilterServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(
        self,
        address: tuple[str, int],
        upstream: tuple[str, int],
        allowed_tools: frozenset[str],
    ) -> None:
        super().__init__(address, ToolFilterHandler)
        self.upstream_host, self.upstream_port = upstream
        self.allowed_tools = allowed_tools


def wait_for_origin(host: str, port: int, process: subprocess.Popen[bytes]) -> None:
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"Canvas MCP origin exited with status {process.returncode}")
        try:
            with socket.create_connection((host, port), timeout=0.25):
                return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError(f"Canvas MCP origin did not listen on {host}:{port}")


def parse_args() -> argparse.Namespace:
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8085)
    parser.add_argument("--origin-port", type=int, default=8086)
    parser.add_argument("--allowlist", type=Path, default=here / "allowed-tools.txt")
    parser.add_argument("--canvas", default="/usr/local/bin/canvas")
    parser.add_argument("--log-level", default="info")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    allowed_tools = load_allowlist(args.allowlist)
    origin_command = [
        args.canvas,
        "mcp",
        "stream",
        "--host",
        "127.0.0.1",
        "--port",
        str(args.origin_port),
        "--readonly",
        "--log-level",
        args.log_level,
    ]
    origin = subprocess.Popen(origin_command)
    server: ToolFilterServer | None = None
    try:
        wait_for_origin("127.0.0.1", args.origin_port, origin)
        server = ToolFilterServer(
            (args.host, args.port),
            ("127.0.0.1", args.origin_port),
            allowed_tools,
        )

        def stop(_signum: int, _frame: Any) -> None:
            assert server is not None
            threading.Thread(target=server.shutdown, daemon=True).start()

        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        print(
            f"Canvas MCP tool filter listening on {args.host}:{args.port}; "
            f"exposing {len(allowed_tools)} tools",
            flush=True,
        )
        server.serve_forever()
        return 0
    finally:
        if server is not None:
            server.server_close()
        origin.terminate()
        try:
            origin.wait(timeout=10)
        except subprocess.TimeoutExpired:
            origin.kill()
            origin.wait()


if __name__ == "__main__":
    raise SystemExit(main())
