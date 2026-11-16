# A one-shot stand-in for atuin's sync server, for the test with the real
# atuin: it listens on 127.0.0.1:PORT, writes READY when it does, records each
# request as a line of JSON (method, path, body) in LOG, and exits after the
# first POST (the login) or after 30 seconds. It answers 200 with a JSON body
# that is no atuin server's reply, so atuin's login stops there; what the test
# needs is the request body.
#
#   python3 -I listener.py PORT LOG READY
import http.server
import json
import sys
import time

port, log_path, ready_path = int(sys.argv[1]), sys.argv[2], sys.argv[3]
done = False


class Handler(http.server.BaseHTTPRequestHandler):
    def respond(self):
        global done
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        with open(log_path, "a") as log:
            log.write(json.dumps({"method": self.command, "path": self.path, "body": body}) + "\n")
        out = b"{}"
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)
        if self.command == "POST":
            done = True

    do_GET = do_POST = do_PUT = respond

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", port), Handler)
server.timeout = 1
open(ready_path, "w").close()
end = time.time() + 30
while not done and time.time() < end:
    server.handle_request()
