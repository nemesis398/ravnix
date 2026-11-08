#!/usr/bin/env python3
"""A minimal MCP client for tests/desktop/chrome-devtools-mcp.nix.

It starts the server command it is given, as Claude Code starts an MCP server
(a child process, JSON-RPC lines over stdio), makes the first tool call right
after the handshake, reads the page back, and stops the server the way Claude
Code does. It prints one JSON document with what happened:

  tools      the names of the tools the server offers
  first      the first call(s) after the handshake: "navigate_page" is list_pages
             (which launches the browser, and names the page to use, since the
             page-scoped tools of the server take a pageId) and then
             navigate_page at once; "new_page" is new_page alone. Its tool,
             how long it took, its text, isError
  snapshot   the text of take_snapshot after it
  script     the text of evaluate_script (document.title)
  calls      the answer to each --call (tool, isError, text), made on the
             page after the snapshot
  exec       the output of each --exec command, run while the server is up
  exit       how the server ended: "stdin-closed" (it exited by itself when its
             stdin closed), "sigterm" (it needed SIGTERM, or --stop sigterm
             asked for one), and its exit code

usage: chrome-devtools-mcp-probe.py --url URL [--first navigate_page|new_page]
           [--stop stdin|sigterm] [--launch-base DIR]
           [--call TOOL=JSON-ARGUMENTS ...] [--exec SHELL-COMMAND ...]
           -- COMMAND [ARGS...]

--call makes one more tool call with the given arguments (JSON), and the id of
the page is added unless they name one. "{t}" in them stands for the TMPDIR of
the launch (the wrapper's t directory, which is where the server's file tools
may read and write): DIR/cdh.PID.*/t, where PID is the server command's own
process, DIR is --launch-base (default /tmp).

Standard library only. Exit status 1 when the server breaks the protocol or
does not answer in time, with the reason on stderr.
"""

import argparse
import glob
import json
import os
import re
import select
import signal
import subprocess
import sys
import time


class Peer:
    def __init__(self, command):
        self.proc = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=sys.stderr,
        )
        self.buffer = b""
        self.next_id = 0

    def send(self, message):
        self.proc.stdin.write((json.dumps(message) + "\n").encode())
        self.proc.stdin.flush()

    def read_line(self, deadline):
        fd = self.proc.stdout.fileno()
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("the server did not answer in time")
            ready, _, _ = select.select([fd], [], [], remaining)
            if not ready:
                raise TimeoutError("the server did not answer in time")
            chunk = os.read(fd, 65536)
            if not chunk:
                raise EOFError("the server closed its stdout")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return line

    def request(self, method, params, timeout):
        self.next_id += 1
        wanted = self.next_id
        self.send({"jsonrpc": "2.0", "id": wanted, "method": method, "params": params})
        deadline = time.monotonic() + timeout
        while True:
            line = self.read_line(deadline)
            if not line.strip():
                continue
            message = json.loads(line)
            if message.get("id") == wanted and ("result" in message or "error" in message):
                if "error" in message:
                    raise RuntimeError("%s failed: %s" % (method, message["error"]))
                return message["result"]
            # A notification, or a request of the server's: not ours to answer.

    def call(self, name, arguments, timeout):
        result = self.request("tools/call", {"name": name, "arguments": arguments}, timeout)
        text = "\n".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")
        return text, bool(result.get("isError"))


def page_id(listing):
    """The id of the selected page in the text of list_pages ("1: URL [selected]")."""
    lines = re.findall(r"^(\d+): .*$", listing, re.M)
    selected = re.findall(r"^(\d+): .*\[selected\]", listing, re.M)
    if not (selected or lines):
        raise RuntimeError("list_pages names no page: %r" % listing)
    return int((selected or lines)[0])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--first", choices=["navigate_page", "new_page"], default="navigate_page")
    parser.add_argument("--stop", choices=["stdin", "sigterm"], default="stdin")
    parser.add_argument("--exec", action="append", default=[], dest="commands")
    parser.add_argument("--call", action="append", default=[], dest="calls", metavar="TOOL=JSON")
    parser.add_argument("--launch-base", default="/tmp")
    parser.add_argument("command", nargs="+")
    args = parser.parse_args()

    peer = Peer(args.command)
    summary = {}
    try:
        init = peer.request(
            "initialize",
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "ravnix-probe", "version": "1"},
            },
            60,
        )
        summary["server"] = init.get("serverInfo", {})
        peer.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        summary["tools"] = sorted(t["name"] for t in peer.request("tools/list", {}, 60)["tools"])

        # The first calls, as soon as the handshake is over: the server
        # launches the browser for them and navigates at once.
        started = time.monotonic()
        if args.first == "navigate_page":
            listing, _ = peer.call("list_pages", {}, 120)
            text, is_error = peer.call(
                "navigate_page",
                {"pageId": page_id(listing), "type": "url", "url": args.url},
                120,
            )
        else:
            text, is_error = peer.call("new_page", {"url": args.url}, 120)
        summary["first"] = {
            "tool": args.first,
            "seconds": round(time.monotonic() - started, 2),
            "text": text,
            "isError": is_error,
        }

        listing, _ = peer.call("list_pages", {}, 60)
        summary["pages"] = listing
        selected = page_id(listing)
        summary["snapshot"], _ = peer.call("take_snapshot", {"pageId": selected}, 60)
        summary["script"], _ = peer.call(
            "evaluate_script", {"pageId": selected, "function": "() => document.title"}, 60
        )

        summary["calls"] = []
        for spec in args.calls:
            tool, _, raw = spec.partition("=")
            if "{t}" in raw:
                launches = glob.glob(os.path.join(args.launch_base, "cdh.%d.*" % peer.proc.pid))
                if len(launches) != 1:
                    raise RuntimeError("expected one launch directory of pid %d in %s, found %r" % (peer.proc.pid, args.launch_base, launches))
                raw = raw.replace("{t}", launches[0] + "/t")
            arguments = json.loads(raw or "{}")
            arguments.setdefault("pageId", selected)
            call_text, call_error = peer.call(tool, arguments, 60)
            summary["calls"].append({"tool": tool, "isError": call_error, "text": call_text[:2000]})

        summary["exec"] = []
        for command in args.commands:
            done = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=60)
            summary["exec"].append(
                {"command": command, "status": done.returncode, "stdout": done.stdout, "stderr": done.stderr}
            )

        if args.stop == "stdin":
            peer.proc.stdin.close()
            try:
                code = peer.proc.wait(timeout=20)
                summary["exit"] = {"how": "stdin-closed", "code": code}
            except subprocess.TimeoutExpired:
                peer.proc.send_signal(signal.SIGTERM)
                code = peer.proc.wait(timeout=20)
                summary["exit"] = {"how": "sigterm", "code": code}
        else:
            peer.proc.send_signal(signal.SIGTERM)
            code = peer.proc.wait(timeout=20)
            summary["exit"] = {"how": "sigterm", "code": code}
    except (TimeoutError, EOFError, RuntimeError, subprocess.TimeoutExpired) as error:
        print("probe: %s" % error, file=sys.stderr)
        peer.proc.kill()
        peer.proc.wait()
        return 1
    print(json.dumps(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
