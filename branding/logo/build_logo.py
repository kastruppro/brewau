"""Builds the brewau logo masters. Usage: python3 build_logo.py <out-dir>"""
import math, sys, os
OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)
KEDEL, MALT, SKUM = "#12343B", "#F2A33A", "#F6F1E7"
f = lambda v: (f"{v:.2f}".rstrip('0').rstrip('.')) if abs(v) > 1e-9 else "0"

class P:
    """Path builder with an affine placement (scale s, offset ox, oy)."""
    def __init__(s, k=1, ox=0, oy=0): s.k, s.ox, s.oy, s.d = k, ox, oy, []
    def t(s, x, y): return f"{f(s.ox + x*s.k)} {f(s.oy + y*s.k)}"
    def r(s, v): return f(v*s.k)
    def rect(s, x0, y0, x1, y1):
        s.d.append(f"M{s.t(x0,y0)}L{s.t(x1,y0)}L{s.t(x1,y1)}L{s.t(x0,y1)}Z")
    def poly(s, pts):
        s.d.append("M" + "L".join(s.t(*p) for p in pts) + "Z")
    def circle(s, cx, cy, r, ccw=False):
        sw = 0 if ccw else 1
        s.d.append(f"M{s.t(cx-r,cy)}A{s.r(r)} {s.r(r)} 0 1 {sw} {s.t(cx+r,cy)}"
                   f"A{s.r(r)} {s.r(r)} 0 1 {sw} {s.t(cx-r,cy)}Z")
    def ring(s, cx, cy, ro, ri):
        s.circle(cx, cy, ro); s.circle(cx, cy, ri, ccw=True)
    def band(s, cx, cy, ro, ri, a0, a1):
        pt = lambda r, a: (cx + r*math.cos(math.radians(a)), cy + r*math.sin(math.radians(a)))
        lg = 1 if (a1 - a0) > 180 else 0
        s.d.append(f"M{s.t(*pt(ro,a0))}A{s.r(ro)} {s.r(ro)} 0 {lg} 1 {s.t(*pt(ro,a1))}"
                   f"L{s.t(*pt(ri,a1))}A{s.r(ri)} {s.r(ri)} 0 {lg} 0 {s.t(*pt(ri,a0))}Z")
    def rrect(s, x, y, w, h, r, ccw=False):
        k = r*0.5523
        if not ccw:
            s.d.append(f"M{s.t(x+r,y)}L{s.t(x+w-r,y)}C{s.t(x+w-r+k,y)} {s.t(x+w,y+r-k)} {s.t(x+w,y+r)}"
                       f"L{s.t(x+w,y+h-r)}C{s.t(x+w,y+h-r+k)} {s.t(x+w-r+k,y+h)} {s.t(x+w-r,y+h)}"
                       f"L{s.t(x+r,y+h)}C{s.t(x+r-k,y+h)} {s.t(x,y+h-r+k)} {s.t(x,y+h-r)}"
                       f"L{s.t(x,y+r)}C{s.t(x,y+r-k)} {s.t(x+r-k,y)} {s.t(x+r,y)}Z")
        else:
            s.d.append(f"M{s.t(x+r,y)}C{s.t(x+r-k,y)} {s.t(x,y+r-k)} {s.t(x,y+r)}"
                       f"L{s.t(x,y+h-r)}C{s.t(x,y+h-r+k)} {s.t(x+r-k,y+h)} {s.t(x+r,y+h)}"
                       f"L{s.t(x+w-r,y+h)}C{s.t(x+w-r+k,y+h)} {s.t(x+w,y+h-r+k)} {s.t(x+w,y+h-r)}"
                       f"L{s.t(x+w,y+r)}C{s.t(x+w,y+r-k)} {s.t(x+w-r+k,y)} {s.t(x+w-r,y)}Z")
    def __str__(s): return "".join(s.d)

# ---- Symbol: sealed boundary with a rising column of brew bubbles (256 grid) ----
BUBBLES = [(120, 172, 11), (144, 136, 16), (124, 90, 22)]
def symbol(k=1, ox=0, oy=0, reversed_=False):
    ring, bub = P(k, ox, oy), P(k, ox, oy)
    inset = 53 if reversed_ else 54          # reversed: ring 1 unit thinner (irradiation)
    ring.rrect(24, 24, 208, 208, 64); ring.rrect(inset, inset, 256-2*inset, 256-2*inset, 64-(inset-24), ccw=True)
    for x, y, r in BUBBLES: bub.circle(x, y, r - (0.75 if reversed_ else 0))
    return ring, bub
def symbol_small():
    # 16 px cut on a 16-unit grid: thicker boundary, two larger bubbles
    ring, bub = P(), P()
    ring.rrect(16, 16, 224, 224, 68); ring.rrect(48, 48, 160, 160, 36, ccw=True)
    bub.circle(120, 96, 32); bub.circle(146, 164, 21)
    return ring, bub

# ---- Wordmark: constructed geometric lowercase, stem 20, bowl ro 52 / ri 31 (overshoot 2) ----
# local metrics: baseline 190, x-height 90, ascender 40
def wordmark(k=1, ox=0, oy=0):
    p = P(k, ox, oy); x = 0
    def at(dx):
        nonlocal x; q = P(k, ox + x*k, oy); x += dx; return q
    parts = []
    q = at(104); q.rect(0, 40, 20, 190); q.ring(52, 140, 52, 31); parts.append(q)          # b
    x += 15
    q = at(78); q.rect(0, 90, 20, 190); q.band(52, 140, 52, 31, 180, 300); parts.append(q)  # r
    x += 5
    q = at(104); q.band(52, 140, 52, 31, 40, 360); q.rect(10, 131, 104, 148); parts.append(q)  # e
    x += 5
    run, t = 100*math.tan(math.radians(15)), 20/math.cos(math.radians(15))   # exact 75 deg diagonals
    q = at(4*run + t)                                                               # w
    for top, bot in [(0, run), (2*run, run), (2*run, 3*run), (4*run, 3*run)]:      # left edges
        q.poly([(top, 90), (top+t, 90), (bot+t, 190), (bot, 190)])
    parts.append(q)
    x += 5
    q = at(104); q.ring(52, 140, 52, 31); q.rect(84, 90, 104, 190); parts.append(q)          # a
    x += 18
    q = at(104); q.rect(0, 90, 20, 140); q.rect(84, 90, 104, 190); q.band(52, 140, 52, 31, 0, 180); parts.append(q)  # u
    return "".join(str(q) for q in parts), x   # path data, advance width (local units)

def svg(w, h, body, title="brewau logo"):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {f(w)} {f(h)}">'
            f'<title>{title}</title>{body}</svg>\n')
def paths(ring, bub, ring_col, bub_col):
    return (f'<path fill="{ring_col}" fill-rule="evenodd" d="{ring}"/>'
            f'<path fill="{bub_col}" d="{bub}"/>')
def write(name, content):
    open(os.path.join(OUT, name), "w").write(content)

r, b = symbol();            write("brewau-symbol.svg", svg(256, 256, paths(r, b, KEDEL, MALT)))
r, b = symbol(reversed_=True); write("brewau-symbol-reversed.svg", svg(256, 256, paths(r, b, SKUM, MALT)))
r, b = symbol_small();      write("brewau-symbol-small.svg", svg(256, 256, paths(r, b, KEDEL, MALT)))

wd, ww = wordmark()
write("brewau-wordmark.svg", svg(ww + 0, 152, f'<path fill="{KEDEL}" d="{wordmark(1, 0, -38)[0]}"/>'))

# horizontal lockup: x-height centred on symbol centre (local 140 -> 128), gap = 40
def horizontal(ring_col, bub_col, word_col, reversed_=False):
    r, b = symbol(reversed_=reversed_)
    wd, ww = wordmark(1, 272, -12)
    return 272 + ww + 24, paths(r, b, ring_col, bub_col) + f'<path fill="{word_col}" d="{wd}"/>'
w, body = horizontal(KEDEL, MALT, KEDEL);  write("brewau-horizontal.svg", svg(w, 256, body))
w, body = horizontal(SKUM, MALT, SKUM, True); write("brewau-horizontal-reversed.svg", svg(w, 256, body))

# stacked lockup: symbol on top, wordmark (scale .8) centred below
_, ww = wordmark(); k = 0.42; W = max(256, ww*k + 48)
sx = (W - 256)/2
r, b = symbol(1, sx, 0)
wd, _ = wordmark(k, (W - ww*k)/2, 256 + 16 - 40*k)
write("brewau-stacked.svg", svg(W, 256 + 16 + 150*k + 24, paths(r, b, KEDEL, MALT) + f'<path fill="{KEDEL}" d="{wd}"/>'))

# app icon (macOS): Kedel tile, Skum boundary, Malt bubbles; 1024 canvas, 824 tile (Apple grid)
def app_icon(src_small=False):
    s = 0.62*824/256 * (256/208); ox = (1024 - 256*s)/2; oy = ox - 1024*0.012
    def rebuild():
        if src_small:
            ring, bub = P(s, ox, oy), P(s, ox, oy)
            ring.rrect(16, 16, 224, 224, 68); ring.rrect(48, 48, 160, 160, 36, ccw=True)
            bub.circle(120, 96, 32); bub.circle(146, 164, 21); return ring, bub
        return symbol(s, ox, oy, reversed_=True)
    ring, bub = rebuild()
    tile = P(); tile.rrect(100, 100, 824, 824, 185)
    return svg(1024, 1024, f'<path fill="{KEDEL}" d="{tile}"/>' + paths(ring, bub, SKUM, MALT), "brewau app icon")
write("brewau-app-icon.svg", app_icon())
write("brewau-app-icon-small.svg", app_icon(True))

# favicon / web-icon source: small cut, reversed, on a Kedel tile (works on light and dark tabs)
s = 0.78; o = 128 - 128*s
ring, bub = P(s, o, o), P(s, o, o)
ring.rrect(16, 16, 224, 224, 68); ring.rrect(48, 48, 160, 160, 36, ccw=True)
bub.circle(120, 96, 32); bub.circle(146, 164, 21)
tile = P(); tile.rrect(0, 0, 256, 256, 56)
write("brewau-favicon-source.svg", svg(256, 256, f'<path fill="{KEDEL}" d="{tile}"/>' + paths(ring, bub, SKUM, MALT), "brewau icon"))

# stacked, reversed (Skum/Malt for dark backgrounds)
_, ww = wordmark(); k = 0.42; W = max(256, ww*k + 48)
r, b = symbol(1, (W - 256)/2, 0, reversed_=True)
wd, _ = wordmark(k, (W - ww*k)/2, 256 + 16 - 40*k)
write("brewau-stacked-reversed.svg", svg(W, 256 + 16 + 150*k + 24, paths(r, b, SKUM, MALT) + f'<path fill="{SKUM}" d="{wd}"/>'))
