"""Tiny SVG library for Chen / Elmasri-Navathe EER diagrams.

Shapes are placed by centre coordinates. Lines are collected first and
drawn underneath the shapes, so they never need clipping.
"""
import html
import math

FONT = "Helvetica, Arial, sans-serif"


def text_width(s, size):
    return len(s) * size * 0.58


class Page:
    def __init__(self, title, subtitle, width=1600, height=1000):
        self.title, self.subtitle = title, subtitle
        self.w, self.h = width, height
        self.nodes = {}
        self.back = []    # lines
        self.front = []   # shapes and labels
        self.top = []     # cardinalities, marks

    # ---------------------------------------------------------- shapes
    def entity(self, nid, x, y, label, weak=False, ref=None, fill="#f4f6f8"):
        w = max(120, len(label) * 13 * 0.68 + 26)
        h = 38
        self.nodes[nid] = dict(kind="rect", x=x, y=y, hw=w / 2, hh=h / 2)
        dash = ' stroke-dasharray="6 4"' if ref else ""
        fill = "#ffffff" if ref else fill
        s = f'<rect x="{x - w / 2}" y="{y - h / 2}" width="{w}" height="{h}" fill="{fill}" stroke="#222" stroke-width="1.4"{dash}/>'
        if weak:
            s += f'<rect x="{x - w / 2 + 4}" y="{y - h / 2 + 4}" width="{w - 8}" height="{h - 8}" fill="none" stroke="#222" stroke-width="1.2"/>'
        s += self._text(x, y + 4.5, label, 13, weight="bold")
        if ref:
            s += self._text(x, y + h / 2 + 12, f"(see {ref})", 9.5, color="#666", italic=True)
        self.front.append(s)

    def rel(self, nid, x, y, label, identifying=False):
        lines = label.split("\n")
        hw = max(52, max(text_width(l, 10.5) for l in lines) / 2 + 22)
        hh = 24 if len(lines) == 1 else 30
        self.nodes[nid] = dict(kind="diamond", x=x, y=y, hw=hw, hh=hh)
        pts = f"{x},{y - hh} {x + hw},{y} {x},{y + hh} {x - hw},{y}"
        s = f'<polygon points="{pts}" fill="#fff" stroke="#222" stroke-width="1.4"/>'
        if identifying:
            k = 0.78
            pts2 = f"{x},{y - hh * k} {x + hw * k},{y} {x},{y + hh * k} {x - hw * k},{y}"
            s += f'<polygon points="{pts2}" fill="none" stroke="#222" stroke-width="1.2"/>'
        y0 = y + 4 - (len(lines) - 1) * 6
        for i, l in enumerate(lines):
            s += self._text(x, y0 + i * 12, l, 10.5, weight="bold")
        self.front.append(s)

    def attr(self, owner, x, y, label, kind="plain", parent_line=True):
        """kind: plain | key | partial | multi | derived | composite"""
        rx = max(30, text_width(label, 11) / 2 + 11)
        ry = 13
        nid = f"{owner}.{label}"
        self.nodes[nid] = dict(kind="ellipse", x=x, y=y, hw=rx, hh=ry)
        if parent_line:
            self._line(self.nodes[owner], self.nodes[nid])
        dash = ' stroke-dasharray="4 3"' if kind == "derived" else ""
        s = f'<ellipse cx="{x}" cy="{y}" rx="{rx}" ry="{ry}" fill="#fff" stroke="#333" stroke-width="1.1"{dash}/>'
        if kind == "multi":
            s += f'<ellipse cx="{x}" cy="{y}" rx="{rx - 3.5}" ry="{ry - 3.5}" fill="none" stroke="#333" stroke-width="1"/>'
        s += self._text(x, y + 4, label, 11)
        if kind in ("key", "partial"):
            uw = len(label) * 11 * 0.5
            ud = ' stroke-dasharray="3 2"' if kind == "partial" else ""
            s += f'<line x1="{x - uw / 2}" y1="{y + 6}" x2="{x + uw / 2}" y2="{y + 6}" stroke="#111" stroke-width="1"{ud}/>'
        self.front.append(s)
        return nid

    def sub_attr(self, parent_nid, x, y, label, kind="plain"):
        # component of a composite attribute
        rx = max(30, text_width(label, 11) / 2 + 11)
        nid = f"{parent_nid}.{label}"
        self.nodes[nid] = dict(kind="ellipse", x=x, y=y, hw=rx, hh=13)
        self._line(self.nodes[parent_nid], self.nodes[nid])
        dash = ' stroke-dasharray="4 3"' if kind == "derived" else ""
        s = f'<ellipse cx="{x}" cy="{y}" rx="{rx}" ry="13" fill="#fff" stroke="#333" stroke-width="1.1"{dash}/>'
        s += self._text(x, y + 4, label, 11)
        self.front.append(s)

    # ---------------------------------------------------------- links
    def link(self, ent, rel, card=None, total=False, role=None, card_pos=0.5):
        """Line between an entity and a relationship. The cardinality is
        written next to the line, between the two shapes."""
        a, b = self.nodes[ent], self.nodes[rel]
        self._line(a, b, double=total)
        pa, pb = self._boundary(a, b), self._boundary(b, a)
        mx = pa[0] + (pb[0] - pa[0]) * card_pos
        my = pa[1] + (pb[1] - pa[1]) * card_pos
        dx, dy = pb[0] - pa[0], pb[1] - pa[1]
        L = math.hypot(dx, dy) or 1
        nx, ny = -dy / L, dx / L
        if card:
            self.top.append(self._label(mx + nx * 11, my + ny * 11 + 4, card, 13, "#b00020"))
        if role:
            off = 14 + abs(nx) * text_width(role, 10) / 2
            self.top.append(self._label(mx - nx * off, my - ny * off + 4, role, 10, "#225", italic=True))

    def isa(self, nid, x, y, symbol, parents, children, total=False, predicate=None, child_labels=None):
        """Specialization (symbol d / o) or category (symbol u).
        Subset marks are drawn on the lines to the *children*."""
        r = 15
        self.nodes[nid] = dict(kind="ellipse", x=x, y=y, hw=r, hh=r)
        for p in parents:
            self._line(self.nodes[p], self.nodes[nid], double=total and symbol != "u")
        for i, c in enumerate(children):
            cn = self.nodes[c]
            self._line(self.nodes[nid], cn, double=total and symbol == "u")
            self._subset_mark(self.nodes[nid], cn)
            if child_labels:
                pa, pb = (x, y), self._boundary(cn, self.nodes[nid])
                mx, my = pa[0] + (pb[0] - pa[0]) * 0.72, pa[1] + (pb[1] - pa[1]) * 0.72
                self.top.append(self._label(mx + 14, my, child_labels[i], 10.5, "#225", italic=True))
        s = f'<circle cx="{x}" cy="{y}" r="{r}" fill="#fff" stroke="#222" stroke-width="1.4"/>'
        s += self._text(x, y + 6, symbol, 17, weight="bold")
        self.front.append(s)
        if predicate:
            self.top.append(self._label(x + 22, y - 18, predicate, 10.5, "#225", italic=True, anchor="start"))

    def note(self, x, y, lines, width=360, title=None):
        h = 18 * len(lines) + (26 if title else 12)
        s = f'<rect x="{x}" y="{y}" width="{width}" height="{h}" rx="6" fill="#f7f9fc" stroke="#9aa7b8"/>'
        yy = y + 18
        if title:
            s += f'<text x="{x + 12}" y="{yy}" font-family="{FONT}" font-size="12" font-weight="bold" fill="#123">{html.escape(title)}</text>'
            yy += 20
        for l in lines:
            s += f'<text x="{x + 12}" y="{yy}" font-family="{FONT}" font-size="11" fill="#223">{html.escape(l)}</text>'
            yy += 18
        self.top.append(s)

    def panel(self, x, y, w, h, label, color):
        s = f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="{color}" fill-opacity="0.35" stroke="{color}" stroke-width="1.5"/>'
        s += f'<text x="{x + 12}" y="{y + 20}" font-family="{FONT}" font-size="13" font-weight="bold" fill="#333">{html.escape(label)}</text>'
        self.back.insert(0, s)

    def raw(self, svg, layer="top"):
        getattr(self, layer).append(svg)

    # ---------------------------------------------------------- output
    def svg(self):
        head = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.w} {self.h}" '
                f'width="{self.w}" height="{self.h}">'
                f'<rect width="100%" height="100%" fill="#fff"/>')
        title = (self._text(self.w / 2, 34, self.title, 22, weight="bold")
                 + self._text(self.w / 2, 56, self.subtitle, 12.5, color="#555"))
        return head + title + "".join(self.back) + "".join(self.front) + "".join(self.top) + "</svg>"

    # ---------------------------------------------------------- helpers
    def _text(self, x, y, s, size, weight="normal", color="#111", italic=False, anchor="middle"):
        st = ' font-style="italic"' if italic else ""
        return (f'<text x="{x}" y="{y}" text-anchor="{anchor}" font-family="{FONT}" font-size="{size}" '
                f'font-weight="{weight}" fill="{color}"{st}>{html.escape(s)}</text>')

    def _label(self, x, y, s, size, color, italic=False, anchor="middle"):
        w = text_width(s, size) + 6
        x0 = x - w / 2 if anchor == "middle" else x - 3
        bg = f'<rect x="{x0}" y="{y - size + 1}" width="{w}" height="{size + 3}" fill="#fff" fill-opacity="0.85"/>'
        return bg + self._text(x, y, s, size, weight="bold" if not italic else "normal", color=color,
                               italic=italic, anchor=anchor)

    def _boundary(self, n, towards):
        dx, dy = towards["x"] - n["x"], towards["y"] - n["y"]
        if dx == 0 and dy == 0:
            return n["x"], n["y"]
        hw, hh = n["hw"], n["hh"]
        if n["kind"] == "rect":
            t = min(hw / abs(dx) if dx else 1e9, hh / abs(dy) if dy else 1e9)
        elif n["kind"] == "diamond":
            t = 1 / (abs(dx) / hw + abs(dy) / hh)
        else:
            t = 1 / math.sqrt((dx / hw) ** 2 + (dy / hh) ** 2)
        return n["x"] + dx * t, n["y"] + dy * t

    def _line(self, a, b, double=False):
        x1, y1, x2, y2 = a["x"], a["y"], b["x"], b["y"]
        if not double:
            self.back.append(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="#333" stroke-width="1.2"/>')
            return
        L = math.hypot(x2 - x1, y2 - y1) or 1
        nx, ny = -(y2 - y1) / L * 2.6, (x2 - x1) / L * 2.6
        for k in (1, -1):
            self.back.append(f'<line x1="{x1 + nx * k}" y1="{y1 + ny * k}" x2="{x2 + nx * k}" y2="{y2 + ny * k}" '
                             f'stroke="#333" stroke-width="1.2"/>')

    def _subset_mark(self, circle, child):
        # "U"-shaped subset symbol whose open side faces the circle
        cb = self._boundary(child, circle)
        mx, my = (circle["x"] + cb[0]) / 2, (circle["y"] + cb[1]) / 2
        dx, dy = cb[0] - circle["x"], cb[1] - circle["y"]
        L = math.hypot(dx, dy) or 1
        ux, uy = dx / L, dy / L
        nx, ny = -uy, ux
        p1 = (mx + nx * 8 - ux * 5, my + ny * 8 - uy * 5)
        p2 = (mx - nx * 8 - ux * 5, my - ny * 8 - uy * 5)
        c1 = (mx + nx * 8 + ux * 9, my + ny * 8 + uy * 9)
        c2 = (mx - nx * 8 + ux * 9, my - ny * 8 + uy * 9)
        self.top.append(f'<path d="M{p1[0]},{p1[1]} C{c1[0]},{c1[1]} {c2[0]},{c2[1]} {p2[0]},{p2[1]}" '
                        f'fill="none" stroke="#111" stroke-width="1.6"/>')
