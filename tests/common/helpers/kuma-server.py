# A stand-in for Uptime Kuma's push endpoint, for tests/common/monitoring.nix:
#
#   python3 kuma-server.py PORT LOG CODE_FILE
#
# Each GET is one line of LOG: the path, the status and the message, decoded
# and separated by tabs. It answers with the HTTP status in CODE_FILE, 200
# while there is none.
import http.server
import os
import sys
import urllib.parse

port, log, code_file = int(sys.argv[1]), sys.argv[2], sys.argv[3]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(url.query)
        line = "\t".join(
            [url.path, ",".join(query.get("status", [])), ",".join(query.get("msg", []))]
        )
        with open(log, "a") as f:
            f.write(line + "\n")
        code = 200
        if os.path.exists(code_file):
            with open(code_file) as f:
                code = int(f.read())
        self.send_response(code)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *args):
        pass


http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
