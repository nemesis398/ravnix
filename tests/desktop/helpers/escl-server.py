"""A scanner that speaks just enough eSCL (AirScan) for sane-airscan: its
capabilities, its status, and one scan job whose page is a given JPEG. A
second request for the next page answers 404, as a scanner with no more paper
does.

  python3 escl-server.py JPEG [PORT [ADDRESS]]

It listens on 127.0.0.1:8080 unless told otherwise, and counts the jobs it
took in JOBS (a file in the working directory), so a test can tell that a scan
reached it.
"""

import http.server
import sys

CAPABILITIES = b"""<?xml version="1.0" encoding="UTF-8"?>
<scan:ScannerCapabilities xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm"
    xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03">
  <pwg:Version>2.0</pwg:Version>
  <pwg:MakeAndModel>Fake Scanner</pwg:MakeAndModel>
  <scan:Platen>
    <scan:PlatenInputCaps>
      <scan:MinWidth>16</scan:MinWidth>
      <scan:MaxWidth>2550</scan:MaxWidth>
      <scan:MinHeight>16</scan:MinHeight>
      <scan:MaxHeight>3507</scan:MaxHeight>
      <scan:MaxScanRegions>1</scan:MaxScanRegions>
      <scan:SettingProfiles>
        <scan:SettingProfile>
          <scan:ColorModes>
            <scan:ColorMode>Grayscale8</scan:ColorMode>
            <scan:ColorMode>RGB24</scan:ColorMode>
          </scan:ColorModes>
          <scan:DocumentFormats>
            <pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>
            <scan:DocumentFormatExt>image/jpeg</scan:DocumentFormatExt>
          </scan:DocumentFormats>
          <scan:SupportedResolutions>
            <scan:DiscreteResolutions>
              <scan:DiscreteResolution>
                <scan:XResolution>300</scan:XResolution>
                <scan:YResolution>300</scan:YResolution>
              </scan:DiscreteResolution>
            </scan:DiscreteResolutions>
          </scan:SupportedResolutions>
        </scan:SettingProfile>
      </scan:SettingProfiles>
      <scan:SupportedIntents>
        <scan:SupportedIntent>Document</scan:SupportedIntent>
      </scan:SupportedIntents>
    </scan:PlatenInputCaps>
  </scan:Platen>
</scan:ScannerCapabilities>
"""

STATUS = b"""<?xml version="1.0" encoding="UTF-8"?>
<scan:ScannerStatus xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm"
    xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03">
  <pwg:Version>2.0</pwg:Version>
  <pwg:State>Idle</pwg:State>
</scan:ScannerStatus>
"""


class Scanner(http.server.BaseHTTPRequestHandler):
    jpeg = b""
    port = 0
    delivered = set()

    def reply(self, code, body=b"", ctype="text/xml", headers=()):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/")
        if path == "/eSCL/ScannerCapabilities":
            self.reply(200, CAPABILITIES)
        elif path == "/eSCL/ScannerStatus":
            self.reply(200, STATUS)
        elif path.endswith("/NextDocument") and path.startswith("/eSCL/ScanJobs/"):
            if path in Scanner.delivered:
                self.reply(404)
            else:
                Scanner.delivered.add(path)
                self.reply(200, Scanner.jpeg, "image/jpeg")
        else:
            self.reply(404)

    def do_POST(self):
        if self.path.rstrip("/") == "/eSCL/ScanJobs":
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            with open("JOBS", "a") as jobs:
                jobs.write("job\n")
            with open("JOBS") as jobs:
                n = len(jobs.readlines())
            host = self.headers.get("Host", "127.0.0.1:%d" % Scanner.port)
            location = "http://%s/eSCL/ScanJobs/%d" % (host, n)
            self.reply(201, headers=[("Location", location)])
        else:
            self.reply(404)

    def do_DELETE(self):
        self.reply(200)

    def log_message(self, fmt, *args):
        sys.stderr.write("escl: " + fmt % args + "\n")


if __name__ == "__main__":
    with open(sys.argv[1], "rb") as f:
        Scanner.jpeg = f.read()
    Scanner.port = int(sys.argv[2]) if len(sys.argv) > 2 else 8080
    address = sys.argv[3] if len(sys.argv) > 3 else "127.0.0.1"
    http.server.ThreadingHTTPServer((address, Scanner.port), Scanner).serve_forever()
