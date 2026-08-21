import json
from pathlib import Path
import tempfile
import unittest

from mcp_tool_filter import (
    disallowed_tool_call,
    filter_tools_body,
    load_allowlist,
    requested_tool,
    rpc_tool_denied,
)


class ToolFilterTests(unittest.TestCase):
    def test_load_allowlist_ignores_comments_and_blanks(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "tools.txt"
            path.write_text("# comment\n\ncanvas_users_me\n canvas_courses_list \n")
            self.assertEqual(
                load_allowlist(path), {"canvas_users_me", "canvas_courses_list"}
            )

    def test_filters_json_tool_list(self):
        body = json.dumps(
            {
                "jsonrpc": "2.0",
                "id": 2,
                "result": {
                    "tools": [
                        {"name": "canvas_users_me"},
                        {"name": "canvas_accounts_list"},
                    ]
                },
            }
        ).encode()
        result = json.loads(
            filter_tools_body(body, "application/json", frozenset({"canvas_users_me"}))
        )
        self.assertEqual(result["result"]["tools"], [{"name": "canvas_users_me"}])

    def test_filters_sse_tool_list(self):
        body = b'event: message\ndata: {"result":{"tools":[{"name":"keep"},{"name":"drop"}]}}\n\n'
        result = filter_tools_body(body, "text/event-stream", frozenset({"keep"}))
        self.assertIn(b'{"name":"keep"}', result)
        self.assertNotIn(b'{"name":"drop"}', result)

    def test_extracts_called_tool_and_builds_denial(self):
        payload = {
            "jsonrpc": "2.0",
            "id": 9,
            "method": "tools/call",
            "params": {"name": "canvas_accounts_list", "arguments": {}},
        }
        self.assertEqual(requested_tool(payload), "canvas_accounts_list")
        denial = json.loads(rpc_tool_denied(payload, requested_tool(payload)))
        self.assertEqual(denial["id"], 9)
        self.assertEqual(denial["error"]["code"], -32601)

    def test_rejects_missing_tool_name_and_batch_bypass(self):
        missing_name = {"id": 1, "method": "tools/call", "params": {}}
        batch = [{"method": "ping"}, missing_name]
        denied = disallowed_tool_call(batch, frozenset({"canvas_users_me"}))
        self.assertEqual(denied, (missing_name, None))


if __name__ == "__main__":
    unittest.main()
