"""A stand-in for the LanguageTool server that the editor's checks go to.

    python3 lt-server.py PORT LOG

It answers the two requests ltex-ls-plus makes, a list of languages and a
check that finds nothing, and appends every request it gets to LOG, with the
body, so a test can see what the editor sent and with which credentials.
"""

import http.server
import json
import sys

port, log_path = int(sys.argv[1]), sys.argv[2]
log = open(log_path, "a", buffering=1)

LANGUAGES = [
    {"name": "English (US)", "code": "en", "longCode": "en-US"},
    {"name": "German (Germany)", "code": "de", "longCode": "de-DE"},
]
CHECKED = {
    "software": {"name": "LanguageTool", "version": "6.0"},
    "language": {"name": "English (US)", "code": "en-US"},
    "matches": [],
}


class Handler(http.server.BaseHTTPRequestHandler):
    def reply(self, body):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        log.write(f"GET {self.path}\n")
        self.reply(LANGUAGES)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode()
        log.write(f"POST {self.path} {body}\n")
        self.reply(CHECKED)

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
