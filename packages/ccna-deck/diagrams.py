#!/usr/bin/env python3
"""Draw the CCNA deck's diagrams as SVG, in the deck's own Catppuccin Mocha.

    python3 diagrams.py <vault>/<media dir>

Every diagram carries its own dark background, so it reads the same inside an
Anki card and inside a light Obsidian theme. Text uses a monospace stack and no
embedded font: an SVG loaded through <img> cannot reach the card's @font-face,
and JetBrains Mono, Menlo and Consolas share a 0.6 em advance, so the layout
holds whichever one the device has.

Diagrams are drawn at about 440 px wide with text no smaller than 13 px, so
they stay legible when a phone card scales them to roughly 350 px.
"""

import sys
from html import escape
from pathlib import Path

BASE, MANTLE, CRUST = "#1e1e2e", "#181825", "#11111b"
SURF0, SURF1, SURF2 = "#313244", "#45475a", "#585b70"
TEXT, SUB0, OVL0 = "#cdd6f4", "#a6adc8", "#6c7086"
MAUVE, BLUE, SAPPH, TEAL = "#cba6f7", "#89b4fa", "#74c7ec", "#94e2d5"
GREEN, YELLOW, PEACH, RED = "#a6e3a1", "#f9e2af", "#fab387", "#f38ba8"
FONT = "JetBrains Mono, Menlo, Consolas, monospace"


class Svg:
    def __init__(self, w, h):
        self.w, self.h, self.parts = w, h, []
        self.parts.append(f'<rect x="0" y="0" width="{w}" height="{h}" fill="{BASE}"/>')

    def add(self, s):
        self.parts.append(s)

    def text(self, x, y, s, size=14, fill=TEXT, anchor="middle", weight=400, italic=False):
        style = ' font-style="italic"' if italic else ""
        self.add(f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}" '
                 f'text-anchor="{anchor}" font-weight="{weight}"{style} '
                 f'dominant-baseline="central">{escape(s)}</text>')

    def rect(self, x, y, w, h, fill=MANTLE, stroke=SURF1, sw=1, dash=False):
        d = ' stroke-dasharray="5 4"' if dash else ""
        self.add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" fill="{fill}" '
                 f'stroke="{stroke}" stroke-width="{sw}"{d}/>')

    def box(self, x, y, w, h, label, sub=None, fill=MANTLE, stroke=SURF1, color=TEXT,
            size=14, weight=700):
        self.rect(x, y, w, h, fill, stroke)
        if sub:
            self.text(x + w / 2, y + h / 2 - 8, label, size, color, weight=weight)
            self.text(x + w / 2, y + h / 2 + 10, sub, 12, SUB0, italic=True)
        else:
            self.text(x + w / 2, y + h / 2, label, size, color, weight=weight)

    def line(self, x1, y1, x2, y2, stroke=SURF2, sw=2, dash=False):
        d = ' stroke-dasharray="5 4"' if dash else ""
        self.add(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{stroke}" '
                 f'stroke-width="{sw}"{d}/>')

    def arrow(self, x1, y1, x2, y2, color=MAUVE, sw=2, dash=False, both=False):
        d = ' stroke-dasharray="6 4"' if dash else ""
        mid = color.strip("#")
        start = f' marker-start="url(#s{mid})"' if both else ""
        self.add(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" '
                 f'stroke-width="{sw}"{d} marker-end="url(#a{mid})"{start}/>')
        self.markers.add(color)

    def circle(self, cx, cy, r, fill=MANTLE, stroke=SURF1, sw=1.5):
        self.add(f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{fill}" stroke="{stroke}" '
                 f'stroke-width="{sw}"/>')

    markers = set()

    def render(self):
        defs = []
        for c in sorted(self.markers):
            m = c.strip("#")
            defs.append(f'<marker id="a{m}" viewBox="0 0 10 10" refX="9" refY="5" '
                        f'markerWidth="7" markerHeight="7" orient="auto">'
                        f'<path d="M0,0 L10,5 L0,10 z" fill="{c}"/></marker>')
            defs.append(f'<marker id="s{m}" viewBox="0 0 10 10" refX="1" refY="5" '
                        f'markerWidth="7" markerHeight="7" orient="auto">'
                        f'<path d="M10,0 L0,5 L10,10 z" fill="{c}"/></marker>')
        return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.w} {self.h}" '
                f'width="{self.w}" height="{self.h}" font-family="{FONT}">'
                f'<defs>{"".join(defs)}</defs>{"".join(self.parts)}</svg>\n')


def new(w, h):
    s = Svg(w, h)
    s.markers = set()
    return s


# ── device icons (simplified, after Cisco's topology icon conventions) ───────
def router(s, cx, cy, r=22, label=None):
    s.circle(cx, cy, r, MANTLE, BLUE, 2)
    for dx, dy in ((0, -1), (0, 1), (-1, 0), (1, 0)):
        s.line(cx + dx * 5, cy + dy * 5, cx + dx * (r - 6), cy + dy * (r - 6), BLUE, 2)
    if label:
        s.text(cx, cy + r + 14, label, 13, SUB0)


def switch(s, cx, cy, w=46, h=30, label=None):
    s.rect(cx - w / 2, cy - h / 2, w, h, MANTLE, TEAL, 2)
    s.line(cx - 14, cy - 5, cx + 14, cy - 5, TEAL, 2)
    s.line(cx - 14, cy + 5, cx + 14, cy + 5, TEAL, 2)
    if label:
        s.text(cx, cy + h / 2 + 14, label, 13, SUB0)


def host(s, cx, cy, label=None, color=TEXT):
    s.rect(cx - 16, cy - 13, 32, 22, MANTLE, color, 1.5)
    s.line(cx - 10, cy + 14, cx + 10, cy + 14, color, 2)
    if label:
        s.text(cx, cy + 28, label, 13, SUB0)


# ── 02 Models ───────────────────────────────────────────────────────────────
def osi_tcpip_map():
    osi = [("7", "Application", "Anwendungsschicht"),
           ("6", "Presentation", "Darstellungsschicht"),
           ("5", "Session", "Sitzungsschicht"),
           ("4", "Transport", "Transportschicht"),
           ("3", "Network", "Vermittlungsschicht"),
           ("2", "Data Link", "Sicherungsschicht"),
           ("1", "Physical", "Bitübertragungsschicht")]
    s = new(460, 470)
    s.text(140, 22, "OSI", 15, MAUVE, weight=700)
    s.text(370, 22, "TCP/IP", 15, MAUVE, weight=700)
    y0, h = 42, 58
    for i, (n, en, de) in enumerate(osi):
        y = y0 + i * h
        s.rect(20, y, 250, h - 6)
        s.text(38, y + (h - 6) / 2, n, 15, MAUVE, weight=700)
        s.text(160, y + 18, en, 14, TEXT, weight=700)
        s.text(160, y + 36, de, 12, SUB0, italic=True)
    spans = [(0, 3, "Application", "Anwendung"), (3, 1, "Transport", "Transport"),
             (4, 1, "Internet", "Internet"), (5, 2, "Network Access", "Netzzugang")]
    for start, n, en, de in spans:
        y = y0 + start * h
        hh = n * h - 6
        s.rect(290, y, 150, hh, CRUST, BLUE)
        s.text(365, y + hh / 2 - 9, en, 14, BLUE, weight=700)
        s.text(365, y + hh / 2 + 9, de, 12, SUB0, italic=True)
    return s


def encapsulation():
    s = new(460, 350)
    rows = [("Data", "Daten", [("Data", 0, YELLOW)]),
            ("Segment", "L4", [("TCP", 1, GREEN), ("Data", 0, YELLOW)]),
            ("Packet", "L3", [("IP", 1, BLUE), ("TCP", 1, GREEN), ("Data", 0, YELLOW)]),
            ("Frame", "L2", [("Eth", 1, MAUVE), ("IP", 1, BLUE), ("TCP", 1, GREEN),
                             ("Data", 0, YELLOW), ("FCS", 1, MAUVE)])]
    y = 20
    for name, layer, cells in rows:
        s.text(12, y + 22, name, 14, TEXT, "start", 700)
        s.text(12, y + 40, layer, 12, SUB0, "start", italic=True)
        x = 450
        widths = {"Data": 120}
        seq = []
        for label, hdr, col in reversed(cells):
            w = 120 if label == "Data" else 52
            x -= w
            seq.append((x, w, label, col))
        for x, w, label, col in seq:
            s.box(x, y + 8, w - 4, 36, label, fill=MANTLE, stroke=col, color=col, size=13)
        y += 64
    s.text(12, y + 22, "Bits", 14, TEXT, "start", 700)
    s.text(12, y + 40, "L1", 12, SUB0, "start", italic=True)
    s.text(300, y + 26, "0 1 1 0 1 0 0 1 1 1 0 1 0 1 1 0", 14, SUB0)
    s.arrow(108, 34, 108, y + 10, OVL0)
    s.text(232, 334, "sending: each layer adds its header", 12, SUB0, italic=True)
    return s


# ── 03 Number systems ───────────────────────────────────────────────────────
def binary_octet():
    s = new(460, 200)
    vals = [128, 64, 32, 16, 8, 4, 2, 1]
    bits = [1, 1, 0, 0, 0, 0, 0, 0]
    x0, w = 22, 52
    s.text(230, 22, "One octet, place values", 14, MAUVE, weight=700)
    for i, (v, b) in enumerate(zip(vals, bits)):
        x = x0 + i * w
        s.text(x + w / 2 - 2, 52, str(v), 14, SUB0)
        s.box(x, 66, w - 4, 44, str(b), fill=CRUST if b else MANTLE,
              stroke=MAUVE if b else SURF1, color=MAUVE if b else OVL0, size=20)
    s.text(230, 140, "128 + 64 = 192", 16, TEXT, weight=700)
    s.text(230, 166, "11000000 (binary) = 192 (decimal)", 13, SUB0, italic=True)
    return s


# ── 08 TCP and UDP ──────────────────────────────────────────────────────────
def ladder(title, left, right, msgs, h=None, note=None):
    rows = len(msgs)
    h = h or 90 + rows * 52 + (24 if note else 0)
    s = new(460, h)
    lx, rx = 70, 390
    s.box(lx - 55, 14, 110, 34, left, color=TEXT)
    s.box(rx - 55, 14, 110, 34, right, color=TEXT)
    s.line(lx, 48, lx, h - 20 - (24 if note else 0), SURF1, 2, dash=True)
    s.line(rx, 48, rx, h - 20 - (24 if note else 0), SURF1, 2, dash=True)
    y = 80
    for label, direction, color, sub in msgs:
        x1, x2 = (lx, rx) if direction == ">" else (rx, lx)
        s.arrow(x1, y + 12, x2, y + 30, color)
        s.text(230, y + 4, label, 14, color, weight=700)
        if sub:
            s.text(230, y + 40, sub, 12, SUB0, italic=True)
        y += 52
    if note:
        s.text(230, h - 18, note, 12, SUB0, italic=True)
    return s


def tcp_handshake():
    return ladder("", "Client", "Server", [
        ("1  SYN", ">", MAUVE, None),
        ("2  SYN-ACK", "<", BLUE, None),
        ("3  ACK", ">", MAUVE, None),
    ], note="connection established")


def tcp_close():
    return ladder("", "Host A", "Host B", [
        ("1  FIN", ">", MAUVE, None),
        ("2  ACK", "<", BLUE, None),
        ("3  FIN", "<", BLUE, None),
        ("4  ACK", ">", MAUVE, None),
    ], note="each side closes its own direction")


# ── 09 Core services ────────────────────────────────────────────────────────
def dhcp_dora():
    return ladder("", "Client", "DHCP server", [
        ("D  Discover (broadcast)", ">", MAUVE, None),
        ("O  Offer", "<", BLUE, None),
        ("R  Request (broadcast)", ">", MAUVE, None),
        ("A  Acknowledge", "<", BLUE, None),
    ], note="Discover, Offer, Request, Acknowledge")


def arp_exchange():
    s = new(460, 300)
    host(s, 70, 50, "PC A")
    s.text(70, 92, "192.168.1.10", 12, SUB0)
    host(s, 390, 50, "PC B")
    s.text(390, 92, "192.168.1.20", 12, SUB0)
    s.box(20, 116, 420, 64, "ARP Request", None, CRUST, MAUVE, MAUVE, 14)
    s.text(230, 116 + 20, "", 1)
    s.parts.pop()
    s.text(230, 150, "Who has 192.168.1.20? Tell 192.168.1.10", 12, TEXT)
    s.text(230, 168, "to FF:FF:FF:FF:FF:FF (broadcast)", 12, SUB0, italic=True)
    s.parts[-4] = s.parts[-4]  # keep order explicit
    s.box(20, 200, 420, 64, "ARP Reply", None, CRUST, BLUE, BLUE, 14)
    s.text(230, 234, "192.168.1.20 is at <MAC of PC B>", 12, TEXT)
    s.text(230, 252, "unicast, straight back to PC A", 12, SUB0, italic=True)
    # move the box titles up so the two text lines fit under them
    out = []
    for p in s.parts:
        if ">ARP Request<" in p:
            p = p.replace('y="148.0"', 'y="130"')
        if ">ARP Reply<" in p:
            p = p.replace('y="232.0"', 'y="214"')
        out.append(p)
    s.parts = out
    return s


def traceroute_ttl():
    s = new(460, 300)
    xs = [50, 170, 290, 410]
    host(s, xs[0], 50, "Source")
    router(s, xs[1], 50, label="R1")
    router(s, xs[2], 50, label="R2")
    host(s, xs[3], 50, "Target")
    for a, b in zip(xs, xs[1:]):
        s.line(a + 24, 50, b - 24, 50, SURF2, 2)
    rows = [(1, xs[1], "R1: Time Exceeded"), (2, xs[2], "R2: Time Exceeded"),
            (3, xs[3], "Target answers")]
    y = 120
    for ttl, stop, reply in rows:
        s.text(12, y, f"TTL={ttl}", 13, MAUVE, "start", 700)
        s.arrow(xs[0] + 30, y, stop - 6, y, MAUVE)
        s.arrow(stop - 6, y + 22, xs[0] + 30, y + 22, BLUE, dash=True)
        s.text((xs[0] + stop) / 2 + 16, y + 38, reply, 12, BLUE)
        y += 60
    return s


# ── 06 Ethernet and MAC ─────────────────────────────────────────────────────
def ethernet_frame():
    s = new(470, 190)
    cells = [("Preamble", "7", OVL0), ("SFD", "1", OVL0), ("Dest MAC", "6", MAUVE),
             ("Src MAC", "6", MAUVE), ("Type", "2", BLUE), ("Payload", "46-1500", YELLOW),
             ("FCS", "4", GREEN)]
    widths = [70, 40, 70, 70, 50, 100, 48]
    x = 10
    for (name, size, col), w in zip(cells, widths):
        s.rect(x, 50, w - 3, 52, MANTLE, col, 1.5)
        s.text(x + (w - 3) / 2, 70, name, 12, col, weight=700)
        s.text(x + (w - 3) / 2, 88, size, 12, SUB0)
        x += w
    s.text(235, 24, "Ethernet II frame (sizes in bytes)", 14, MAUVE, weight=700)
    s.line(120, 116, 455, 116, SURF2, 1.5)
    s.line(120, 110, 120, 122, SURF2, 1.5)
    s.line(455, 110, 455, 122, SURF2, 1.5)
    s.text(286, 136, "the frame proper: 64 to 1518 bytes", 12, SUB0, italic=True)
    s.text(60, 136, "not counted", 12, OVL0, italic=True)
    s.text(235, 168, "payload of 1500 bytes = the standard MTU", 12, SUB0, italic=True)
    return s


def mac_address():
    s = new(460, 170)
    s.text(230, 24, "MAC address: 48 bits, 12 hex digits", 14, MAUVE, weight=700)
    s.box(30, 50, 196, 50, "00:1A:2B", fill=CRUST, stroke=MAUVE, color=MAUVE, size=18)
    s.box(234, 50, 196, 50, "3C:4D:5E", fill=CRUST, stroke=BLUE, color=BLUE, size=18)
    s.text(128, 120, "OUI, 24 bits", 13, MAUVE, weight=700)
    s.text(128, 140, "vendor (IEEE-assigned)", 12, SUB0, italic=True)
    s.text(332, 120, "24 bits", 13, BLUE, weight=700)
    s.text(332, 140, "assigned by the vendor", 12, SUB0, italic=True)
    return s


def switch_learning():
    s = new(460, 300)
    switch(s, 230, 70, 70, 36)
    s.text(230, 30, "Switch", 13, SUB0)
    ports = [(80, "Gi0/1", "PC A", "AAAA"), (230, "Gi0/2", "PC B", "BBBB"),
             (380, "Gi0/3", "PC C", "CCCC")]
    for x, p, name, mac in ports:
        s.line(230, 88, x, 150, SURF2, 2)
        s.text(x, 134 if x != 230 else 120, p, 12, TEAL)
        host(s, x, 170, f"{name}  {mac}")
    s.rect(110, 218, 240, 70, CRUST, SURF1)
    s.text(230, 232, "MAC address table", 12, MAUVE, weight=700)
    s.text(230, 254, "AAAA  Gi0/1   learned", 12, TEXT)
    s.text(230, 274, "from the SOURCE address", 12, SUB0, italic=True)
    return s


def domains():
    s = new(460, 300)
    router(s, 230, 40)
    s.text(262, 40, "Router", 13, SUB0, "start")
    s.line(214, 54, 120, 100, SURF2, 2)
    s.line(246, 54, 350, 100, SURF2, 2)
    # left: switch, one collision domain per port
    s.rect(14, 86, 212, 176, "none", BLUE, 1.5)
    switch(s, 120, 112)
    s.text(60, 112, "Switch", 12, SUB0, "end")
    for x in (56, 120, 184):
        s.line(120, 128, x, 176, SURF2, 2)
        s.rect(x - 28, 168, 56, 54, "none", TEAL, 1.5, dash=True)
        host(s, x, 190)
    # right: hub, one shared collision domain
    s.rect(236, 86, 212, 176, "none", BLUE, 1.5)
    s.add('<polygon points="338,100 362,100 368,126 332,126" fill="#181825" '
          'stroke="#f9e2af" stroke-width="2"/>')
    s.text(378, 112, "Hub", 12, SUB0, "start")
    for x in (286, 350, 414):
        s.line(350, 126, x, 176, SURF2, 2)
        host(s, x, 190)
    s.rect(252, 166, 196 - 16, 58, "none", YELLOW, 1.5, dash=True)
    s.text(120, 240, "3 collision domains", 12, TEAL)
    s.text(342, 240, "1 collision domain", 12, YELLOW)
    s.text(230, 280, "the router splits broadcast domains: 2 here", 12, BLUE)
    return s


# ── 05 Cabling ──────────────────────────────────────────────────────────────
def t568_pinout():
    a = [("white/green", GREEN, True), ("green", GREEN, False), ("white/orange", PEACH, True),
         ("blue", BLUE, False), ("white/blue", BLUE, True), ("orange", PEACH, False),
         ("white/brown", "#c9a26b", True), ("brown", "#c9a26b", False)]
    b = [a[2], a[5], a[0], a[3], a[4], a[1], a[6], a[7]]
    s = new(460, 300)
    for col, (title, seq) in enumerate((("T568A", a), ("T568B", b))):
        x0 = 30 + col * 220
        s.text(x0 + 90, 22, title, 15, MAUVE, weight=700)
        for i, (name, c, white) in enumerate(seq):
            y = 44 + i * 30
            s.text(x0 + 6, y + 12, str(i + 1), 13, SUB0, "start")
            s.rect(x0 + 24, y + 3, 40, 18, TEXT if white else c, c, 2)
            if white:
                s.rect(x0 + 38, y + 3, 12, 18, c, c, 0)
            s.text(x0 + 74, y + 12, name, 12, TEXT, "start")
    s.text(230, 290, "A and B swap the green and orange pairs", 12, SUB0, italic=True)
    return s


def fiber_modes():
    s = new(460, 256)
    s.text(230, 20, "Single-mode vs. multimode fiber", 14, MAUVE, weight=700)
    # single-mode
    s.rect(20, 44, 420, 60, MANTLE, SURF1)
    s.rect(20, 69, 420, 10, CRUST, BLUE, 1)
    s.line(30, 74, 430, 74, BLUE, 2)
    s.text(230, 118, "single-mode (SMF): ~9 µm core, one path", 12, BLUE, weight=700)
    s.text(230, 134, "laser, long distances", 12, SUB0, italic=True)
    # multimode
    s.rect(20, 150, 420, 56, MANTLE, SURF1)
    s.rect(20, 158, 420, 40, CRUST, TEAL, 1)
    pts = " ".join(f"{30 + i * 40},{158 if i % 2 else 194}" for i in range(11))
    s.add(f'<polyline points="{pts}" fill="none" stroke="{TEAL}" stroke-width="2"/>')
    s.line(30, 176, 430, 176, TEAL, 1.5)
    s.text(230, 220, "multimode (MMF): 50 or 62.5 µm core, many paths", 12, TEAL, weight=700)
    s.text(230, 236, "LED or VCSEL, shorter distances", 12, SUB0, italic=True)
    return s


# ── 04 Topologies ───────────────────────────────────────────────────────────
def node(s, x, y, c=TEXT):
    s.circle(x, y, 9, MANTLE, c, 2)


def topo(kind):
    s = new(300, 220)
    cx, cy = 150, 110
    import math
    ring = [(cx + 75 * math.cos(math.radians(a)), cy + 75 * math.sin(math.radians(a)))
            for a in range(-90, 270, 72)]
    if kind == "star":
        for x, y in ring:
            s.line(cx, cy, x, y, SURF2, 2)
            node(s, x, y)
        switch(s, cx, cy, 36, 24)
    elif kind == "bus":
        s.line(30, cy, 270, cy, MAUVE, 3)
        s.rect(22, cy - 6, 8, 12, MAUVE, MAUVE)
        s.rect(270, cy - 6, 8, 12, MAUVE, MAUVE)
        for i, x in enumerate((60, 120, 180, 240)):
            y = cy - 50 if i % 2 else cy + 50
            s.line(x, cy, x, y, SURF2, 2)
            node(s, x, y)
    elif kind == "ring":
        for (x1, y1), (x2, y2) in zip(ring, ring[1:] + ring[:1]):
            s.line(x1, y1, x2, y2, SURF2, 2)
        for x, y in ring:
            node(s, x, y)
    elif kind == "full-mesh":
        for i, (x1, y1) in enumerate(ring):
            for x2, y2 in ring[i + 1:]:
                s.line(x1, y1, x2, y2, SURF2, 2)
        for x, y in ring:
            node(s, x, y)
    elif kind == "partial-mesh":
        edges = [(0, 1), (1, 2), (2, 3), (3, 4), (4, 0), (0, 2), (1, 3)]
        for a, b in edges:
            s.line(*ring[a], *ring[b], SURF2, 2)
        for x, y in ring:
            node(s, x, y)
    elif kind == "extended-star":
        hubs = [(90, cy), (210, cy)]
        s.line(90, cy, 210, cy, SURF2, 2)
        for hx, hy in hubs:
            for dx, dy in ((-50, -60), (-50, 60), (0, -70) if hx < 150 else (0, 70)):
                x, y = hx + (dx if hx < 150 else -dx), hy + dy
                s.line(hx, hy, x, y, SURF2, 2)
                node(s, x, y)
        for hx, hy in hubs:
            switch(s, hx, hy, 36, 24)
    return s


def campus_tiers():
    s = new(480, 300)
    s.text(12, 40, "Core", 13, MAUVE, "start", 700)
    s.text(12, 130, "Distribution", 13, MAUVE, "start", 700)
    s.text(12, 220, "Access", 13, MAUVE, "start", 700)
    core = [(250, 40), (370, 40)]
    dist = [(190, 130), (270, 130), (350, 130), (430, 130)]
    acc = [(170, 220), (225, 220), (280, 220), (340, 220), (395, 220), (450, 220)]
    for cx, cy in core:
        for dx, dy in dist:
            s.line(cx, cy, dx, dy, SURF2, 1.5)
    for i, (dx, dy) in enumerate(dist[:2]):
        for ax, ay in acc[:3]:
            s.line(dx, dy, ax, ay, SURF2, 1.5)
    for dx, dy in dist[2:]:
        for ax, ay in acc[3:]:
            s.line(dx, dy, ax, ay, SURF2, 1.5)
    for x, y in core + dist:
        switch(s, x, y, 40, 24)
    for x, y in acc:
        switch(s, x, y, 34, 20)
    s.text(240, 270, "three-tier", 12, SUB0, italic=True)
    s.text(240, 288, "two-tier = core + distribution merged (collapsed core)", 12, SUB0, italic=True)
    return s


def spine_leaf():
    s = new(460, 230)
    spines = [190, 340]
    leaves = [110, 214, 318, 420]
    for x in spines:
        for l in leaves:
            s.line(x, 50, l, 150, SURF2, 1.5)
    for x in spines:
        switch(s, x, 50, 50, 26)
    for l in leaves:
        switch(s, l, 150, 46, 24)
    s.text(12, 50, "Spine", 13, MAUVE, "start", 700)
    s.text(12, 150, "Leaf", 13, MAUVE, "start", 700)
    s.text(265, 200, "every leaf connects to every spine,", 12, SUB0, italic=True)
    s.text(265, 218, "so leaf to leaf is always via one spine", 12, SUB0, italic=True)
    return s


# ── 07 IPv4 / 10 IPv6 ───────────────────────────────────────────────────────
def ipv4_network_host():
    s = new(460, 210)
    s.text(230, 22, "192.168.1.10/24", 16, MAUVE, weight=700)
    octs = ["192", "168", "1", "10"]
    for i, o in enumerate(octs):
        x = 30 + i * 102
        col = BLUE if i < 3 else GREEN
        s.box(x, 46, 96, 44, o, fill=CRUST, stroke=col, color=col, size=18)
        s.text(x + 48, 108, f"{int(o):08b}", 12, SUB0)
    s.line(30, 128, 330, 128, BLUE, 2)
    s.line(336, 128, 430, 128, GREEN, 2)
    s.text(180, 146, "network portion, 24 bits", 12, BLUE, weight=700)
    s.text(180, 164, "Netzanteil", 12, SUB0, italic=True)
    s.text(383, 146, "host, 8 bits", 12, GREEN, weight=700)
    s.text(383, 164, "Hostanteil", 12, SUB0, italic=True)
    s.text(230, 194, "mask 255.255.255.0 = 24 ones, then 8 zeros", 12, SUB0)
    return s


def ipv6_structure():
    s = new(470, 200)
    s.text(235, 22, "2001:0db8:0000:0001:0000:0000:0000:0001", 13, TEXT, weight=700)
    hx = ["2001", "0db8", "0000", "0001", "0000", "0000", "0000", "0001"]
    for i, h in enumerate(hx):
        x = 12 + i * 57
        col = BLUE if i < 4 else GREEN
        s.box(x, 44, 53, 36, h, fill=CRUST, stroke=col, color=col, size=13)
    s.line(12, 96, 236, 96, BLUE, 2)
    s.line(240, 96, 464, 96, GREEN, 2)
    s.text(124, 114, "prefix /64", 12, BLUE, weight=700)
    s.text(352, 114, "interface ID, 64 bits", 12, GREEN, weight=700)
    s.text(235, 148, "short form: 2001:db8:0:1::1", 15, MAUVE, weight=700)
    s.text(235, 174, "8 groups of 16 bits = 128 bits", 12, SUB0, italic=True)
    return s


def ipv6_eui64():
    s = new(460, 300)
    s.text(230, 20, "Modified EUI-64 from a MAC address", 14, MAUVE, weight=700)
    s.text(230, 50, "MAC   00:1A:2B:3C:4D:5E", 14, TEXT)
    s.text(230, 84, "1  split in half", 12, SUB0, italic=True)
    s.box(40, 98, 150, 34, "001A2B", fill=CRUST, stroke=BLUE, color=BLUE, size=14)
    s.box(270, 98, 150, 34, "3C4D5E", fill=CRUST, stroke=BLUE, color=BLUE, size=14)
    s.text(230, 150, "2  insert FFFE in the middle", 12, SUB0, italic=True)
    s.box(20, 164, 130, 34, "001A2B", fill=CRUST, stroke=BLUE, color=BLUE, size=14)
    s.box(160, 164, 130, 34, "FFFE", fill=CRUST, stroke=MAUVE, color=MAUVE, size=14)
    s.box(300, 164, 130, 34, "3C4D5E", fill=CRUST, stroke=BLUE, color=BLUE, size=14)
    s.text(230, 218, "3  flip the 7th bit of the first byte: 00 → 02", 12, SUB0, italic=True)
    s.text(230, 252, "interface ID  021A:2BFF:FE3C:4D5E", 15, GREEN, weight=700)
    s.text(230, 278, "0x00 = 00000000 → 00000010 = 0x02", 12, SUB0)
    return s


DIAGRAMS = {
    "ccna-osi-tcpip-map": osi_tcpip_map,
    "ccna-encapsulation": encapsulation,
    "ccna-binary-octet": binary_octet,
    "ccna-tcp-handshake": tcp_handshake,
    "ccna-tcp-close": tcp_close,
    "ccna-dhcp-dora": dhcp_dora,
    "ccna-arp-exchange": arp_exchange,
    "ccna-traceroute-ttl": traceroute_ttl,
    "ccna-ethernet-frame": ethernet_frame,
    "ccna-mac-address": mac_address,
    "ccna-switch-learning": switch_learning,
    "ccna-domains": domains,
    "ccna-t568-pinout": t568_pinout,
    "ccna-fiber-modes": fiber_modes,
    "ccna-topo-star": lambda: topo("star"),
    "ccna-topo-extended-star": lambda: topo("extended-star"),
    "ccna-topo-bus": lambda: topo("bus"),
    "ccna-topo-ring": lambda: topo("ring"),
    "ccna-topo-full-mesh": lambda: topo("full-mesh"),
    "ccna-topo-partial-mesh": lambda: topo("partial-mesh"),
    "ccna-campus-tiers": campus_tiers,
    "ccna-spine-leaf": spine_leaf,
    "ccna-ipv4-network-host": ipv4_network_host,
    "ccna-ipv6-structure": ipv6_structure,
    "ccna-ipv6-eui64": ipv6_eui64,
}


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: diagrams.py <output dir>")
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    for name, fn in DIAGRAMS.items():
        (out / f"{name}.svg").write_text(fn().render(), encoding="utf-8")
    print(f"{len(DIAGRAMS)} diagrams → {out}")


if __name__ == "__main__":
    main()
