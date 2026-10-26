#!/usr/bin/env python3
"""Generate the README architecture diagram, one SVG per colour scheme.

Two files rather than one self-switching file: GitHub strips <style> blocks
from inline SVG, so a `prefers-color-scheme` media query inside the document is
silently dropped. The README pairs them with <picture>, which GitHub honours.

A README diagram is studied, not narrated, so it is COMPLETE rather than
minimal: the NAT gateway, the database, the secret store and the domain
membership of both targets are all on it.

Run:  python3 make_diagram.py
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))

# ------------------------------------------------------------------------------
# Geometry and style (shared with the other projects' diagrams)
# ------------------------------------------------------------------------------
NW, NH = 420, 110                          # node width, height
GUTTER = 140                               # between columns: room for a label
MARGIN = 40
COL = [MARGIN + i * (NW + GUTTER) for i in range(3)]
ROW = [40, 240, 440, 640]
W = MARGIN * 2 + NW * 3 + GUTTER * 2
H = ROW[3] + NH + 40
TITLE_PX, SUB_PX, EDGE_PX = 26, 17, 16

THEMES = {
    "dark": {
        "bg": "#0d1117", "panel": "#161b22", "text": "#e6edf3",
        "muted": "#8b949e", "line": "#58a6ff", "local": "#39c5bb",
        "purple": "#c39be8", "navy": "#c8d6e8", "blue": "#58a6ff",
        "amber": "#f2c163", "store": "#7ee787",
    },
    "light": {
        "bg": "#ffffff", "panel": "#f6f8fa", "text": "#1f2328",
        "muted": "#59636e", "line": "#0969da", "local": "#137e77",
        "purple": "#8250df", "navy": "#475467", "blue": "#0969da",
        "amber": "#9a6700", "store": "#1a7f37",
    },
}

# Lucide icon paths, on a 24-unit grid.
ICONS = {
    "globe": ['<circle cx="12" cy="12" r="10"/>',
              '<path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"/>',
              '<path d="M2 12h20"/>'],
    "route": ['<circle cx="6" cy="19" r="3"/>', '<circle cx="18" cy="5" r="3"/>',
              '<path d="M12 19h4.5a3.5 3.5 0 0 0 0-7h-8a3.5 3.5 0 0 1 0-7H12"/>'],
    "network": ['<rect x="16" y="16" width="6" height="6" rx="1"/>',
                '<rect x="2" y="16" width="6" height="6" rx="1"/>',
                '<rect x="9" y="2" width="6" height="6" rx="1"/>',
                '<path d="M5 16v-3a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1v3"/>',
                '<path d="M12 12V8"/>'],
    "layers": ['<path d="m12.83 2.18a2 2 0 0 0-1.66 0L2.6 6.08a1 1 0 0 0 0 1.83'
               'l8.58 3.91a2 2 0 0 0 1.66 0l8.58-3.9a1 1 0 0 0 0-1.83Z"/>',
               '<path d="m22 17.65-9.17 4.16a2 2 0 0 1-1.66 0L2 17.65"/>',
               '<path d="m22 12.65-9.17 4.16a2 2 0 0 1-1.66 0L2 12.65"/>'],
    "database": ['<ellipse cx="12" cy="5" rx="9" ry="3"/>',
                 '<path d="M3 5V19A9 3 0 0 0 21 19V5"/>',
                 '<path d="M3 12A9 3 0 0 0 21 12"/>'],
    "key": ['<path d="M2.586 17.414A2 2 0 0 0 2 18.828V21a1 1 0 0 0 1 1h3a1 1 0 0 0 '
            '1-1v-1a1 1 0 0 1 1-1h1a1 1 0 0 0 1-1v-1a1 1 0 0 1 1-1h.172a2 2 0 0 0 '
            '1.414-.586l.814-.814a6.5 6.5 0 1 0-4-4z"/>',
            '<circle cx="16.5" cy="7.5" r=".5"/>'],
    "monitor": ['<rect width="20" height="14" x="2" y="3" rx="2"/>',
                '<line x1="8" x2="16" y1="21" y2="21"/>',
                '<line x1="12" x2="12" y1="17" y2="21"/>'],
    "terminal": ['<polyline points="4 17 10 11 4 5"/>',
                 '<line x1="12" x2="20" y1="19" y2="19"/>'],
    "users": ['<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/>',
              '<circle cx="9" cy="7" r="4"/>',
              '<path d="M22 21v-2a4 4 0 0 0-3-3.87"/>',
              '<path d="M16 3.13a4 4 0 0 1 0 7.75"/>'],
}

NODES = {}


def _r(nid):
    """Return (left, top, right, bottom, centre-x, centre-y) for a node."""
    x, y = NODES[nid][0], NODES[nid][1]
    return x, y, x + NW, y + NH, x + NW / 2, y + NH / 2


def gutter_x(c):
    """Centre of the gutter to the right of column c."""
    return COL[c] + NW + GUTTER / 2


# ------------------------------------------------------------------------------
# Layout
# ------------------------------------------------------------------------------
# The request path runs down the middle column: browser -> App Gateway ->
# Guacamole, which is the hub (amber, the subject of the project). Its
# supporting pieces sit beside it -- PostgreSQL left, Key Vault right, the NAT
# gateway up in the top row -- its two targets fan out below, and the domain
# controller anchors the bottom, joined to everything that authenticates.
#
# id: (x, y, colour key, icon, title, subtitle)
NODES.update({
    "browser":  (COL[0], ROW[0], "navy", "globe", "Browser", "HTTPS only, no client"),
    "alb":      (COL[1], ROW[0], "blue", "route", "Application Gateway",
                 "v2, self-signed cert, own subnet"),
    "nat":      (COL[2], ROW[0], "navy", "network", "NAT Gateway",
                 "outbound for the private servers"),
    "postgres": (COL[0], ROW[1], "store", "database", "PostgreSQL",
                 "connections, group permissions"),
    "guac":     (COL[1], ROW[1], "amber", "layers", "Guacamole",
                 "guacd + web app, private VM"),
    "secrets":  (COL[2], ROW[1], "store", "key", "Key Vault",
                 "AD credentials, gateway cert"),
    "windows":  (COL[0], ROW[2], "blue", "monitor", "Windows Server 2022",
                 "private, RDP from Guacamole only"),
    "linux":    (COL[2], ROW[2], "blue", "monitor", "Lubuntu 26.04",
                 "Packer image: LXQt + XRDP, private"),
    "dc":       (COL[1], ROW[3], "purple", "users", "mini-AD (Samba DC)",
                 "users, groups, LDAPS, Kerberos, DNS"),
})

g = _r("guac")
alb, brw, nat = _r("alb"), _r("browser"), _r("nat")
pg, sec, win, lin, dc = _r("postgres"), _r("secrets"), _r("windows"), _r("linux"), _r("dc")
FAN = 60                      # the three lines leaving Guacamole's underside
MID3 = dc[5]                             # members enter the DC box from its sides

# id: (path, colour key, label, label_x, label_y, anchor)
EDGES = {
    "e_https": (f"M{brw[2]},{brw[5]} L{alb[0] - 5},{alb[5]}", "line",
                "HTTPS :443", gutter_x(0), brw[5] - 12, "middle"),
    "e_alb":   (f"M{alb[4]},{alb[3]} L{alb[4]},{g[1] - 5}", "line",
                "HTTP :8080", alb[4] - 16, (alb[3] + g[1]) / 2 + 6, "end"),
    "e_nat":   (f"M{g[2] - 70},{g[1]} V{(alb[3] + g[1]) / 2} H{nat[4]} V{nat[3] + 5}",
                "navy", "image pulls, updates", gutter_x(1) + 40,
                (alb[3] + g[1]) / 2 - 10, "middle"),
    "e_pg":    (f"M{g[0]},{g[5]} L{pg[2] + 5},{pg[5]}", "store",
                "connections", gutter_x(0), g[5] - 12, "middle"),
    "e_sec":   (f"M{g[2]},{g[5]} L{sec[0] - 5},{sec[5]}", "store",
                "bind password", gutter_x(1), g[5] - 12, "middle"),
    "e_rdp":   (f"M{g[4] - FAN},{g[3]} V{win[5]} H{win[2] + 5}", "local",
                "RDP :3389", (g[4] - FAN + win[2]) / 2, win[5] - 12, "middle"),
    "e_ssh":   (f"M{g[4] + FAN},{g[3]} V{lin[5]} H{lin[0] - 5}", "local",
                "RDP :3389 + SSH :22", (g[4] + FAN + lin[0]) / 2, lin[5] - 12, "middle"),
    "e_ldaps": (f"M{g[4]},{g[3]} V{dc[1] - 5}", "purple",
                "LDAPS :636 sign-in", g[4] + 14, dc[1] - 30, "start"),
    "e_winad": (f"M{win[4]},{win[3]} V{MID3} H{dc[0] - 5}", "purple",
                "domain member", (win[4] + dc[0]) / 2, MID3 - 12, "middle"),
    "e_linad": (f"M{lin[4]},{lin[3]} V{MID3} H{dc[2] + 5}", "purple",
                "SSSD (AD provider)", (lin[4] + dc[2]) / 2, MID3 - 12, "middle"),
}

ALT = ("A browser reaches an internet-facing Application Gateway over HTTPS; it "
       "forwards to a private Guacamole server, which signs users in against the "
       "mini-AD domain controller over LDAPS, keeps its connections in PostgreSQL, "
       "reads its LDAP bind password from Key Vault, and opens RDP to a private "
       "Windows host, and RDP and SSH to a private Lubuntu desktop host built "
       "from a Packer image, both joined to the domain. "
       "The private servers reach the internet through a NAT gateway.")

# ------------------------------------------------------------------------------
# Rendering
# ------------------------------------------------------------------------------
FONT = "-apple-system, BlinkMacSystemFont, Segoe UI, Helvetica, Arial, sans-serif"


def node_svg(nid, t):
    """Render one service box: rounded panel, icon, title, subtitle."""
    x, y, key, icon, title, sub = NODES[nid]
    colour = t[key]
    scale = 1.25
    isz = 24 * scale
    ix, iy = x + 20, y + (NH - isz) / 2
    tx = x + 20 + isz + 14
    return "".join([
        f'<rect x="{x}" y="{y}" width="{NW}" height="{NH}" rx="10" ry="10" '
        f'fill="{t["panel"]}" stroke="{colour}" stroke-width="2"/>',
        f'<g transform="translate({ix},{iy}) scale({scale})" fill="none" '
        f'stroke="{colour}" stroke-width="2" stroke-linecap="round" '
        f'stroke-linejoin="round">' + "".join(ICONS[icon]) + "</g>",
        f'<text x="{tx}" y="{y + NH/2 - 4}" font-family="{FONT}" '
        f'font-size="{TITLE_PX}" font-weight="600" fill="{t["text"]}">{title}</text>',
        f'<text x="{tx}" y="{y + NH/2 + 22}" font-family="{FONT}" '
        f'font-size="{SUB_PX}" fill="{t["muted"]}">{sub}</text>',
    ])


def edge_svg(eid, t):
    """Render one arrow plus its label (on a background chip, so lines that
    pass behind a label never cut through its text)."""
    d, key, label, lx, ly, anchor = EDGES[eid]
    colour = t[key]
    out = (f'<path d="{d}" fill="none" stroke="{colour}" stroke-width="2" '
           f'marker-end="url(#a_{eid})"/>')
    if label:
        out += (f'<text x="{lx}" y="{ly}" text-anchor="{anchor}" '
                f'font-family="{FONT}" font-size="{EDGE_PX}" font-weight="600" '
                f'fill="{colour}" stroke="{t["bg"]}" stroke-width="6" '
                f'paint-order="stroke">{label}</text>')
    return out


def build(t):
    """Assemble the diagram for one theme."""
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
           f'viewBox="0 0 {W} {H}" role="img" aria-label="{ALT}">', "<defs>"]
    # One marker per edge: a shared marker cannot carry per-edge colour.
    for eid, spec in EDGES.items():
        out.append(
            f'<marker id="a_{eid}" viewBox="0 0 10 10" refX="9" refY="5" '
            f'markerWidth="5" markerHeight="5" orient="auto-start-reverse">'
            f'<path d="M0,0 L10,5 L0,10 z" fill="{t[spec[1]]}"/></marker>')
    out.append("</defs>")
    out.append(f'<rect width="{W}" height="{H}" fill="{t["bg"]}"/>')
    for eid in EDGES:
        out.append(edge_svg(eid, t))
    for nid in NODES:
        out.append(node_svg(nid, t))
    out.append("</svg>")
    return "".join(out)


def main():
    for name, theme in THEMES.items():
        path = os.path.join(HERE, f"architecture-{name}.svg")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(build(theme))
        print(f"  architecture-{name}.svg")


if __name__ == "__main__":
    main()
