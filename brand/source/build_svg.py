import os
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.boundsPen import BoundsPen
INK, GRAPE, LILAC, BLUSH, MINT = "#1B1633","#5B3FD9","#A794FF","#FFA8CF","#43D9A3"
BR_DEFAULT = '<path d="M20 38V28a8 8 0 0 1 8-8h10"/><path d="M62 20h10a8 8 0 0 1 8 8v10"/><path d="M80 62v10a8 8 0 0 1-8 8H62"/><path d="M38 80H28a8 8 0 0 1-8-8V62"/>'
BR_WHOA = '<path d="M16 36V24a8 8 0 0 1 8-8h12"/><path d="M64 16h12a8 8 0 0 1 8 8v12"/><path d="M84 64v12a8 8 0 0 1-8 8H64"/><path d="M36 84H24a8 8 0 0 1-8-8V64"/>'
def brackets(color, d=BR_DEFAULT, w=7):
    return f'<g fill="none" stroke="{color}" stroke-width="{w}" stroke-linecap="round" stroke-linejoin="round">{d}</g>'
def blush(x=31): return f'<ellipse cx="{x}" cy="58" rx="5" ry="3" fill="{BLUSH}"/><ellipse cx="{100-x}" cy="58" rx="5" ry="3" fill="{BLUSH}"/>'
EYE = lambda cx: f'<ellipse cx="{cx}" cy="47" rx="5" ry="6.5" fill="{INK}"/><circle cx="{cx+1.8}" cy="44.6" r="1.7" fill="#fff"/>'
SMILE = f'<path d="M43 58q7 7 14 0" fill="none" stroke="{INK}" stroke-width="4.5" stroke-linecap="round"/>'
FACES = {
 "hi":   lambda c: brackets(c) + blush() + EYE(40) + EYE(60) + SMILE,
 "whoa": lambda c: brackets(c, BR_WHOA) + blush(28) + f'<ellipse cx="39" cy="45" rx="6.5" ry="8" fill="{INK}"/><ellipse cx="61" cy="45" rx="6.5" ry="8" fill="{INK}"/><circle cx="41.2" cy="42" r="2" fill="#fff"/><circle cx="63.2" cy="42" r="2" fill="#fff"/><ellipse cx="50" cy="64" rx="4.5" ry="5.5" fill="{INK}"/>',
 "tidy": lambda c: brackets(c) + blush() + f'<g fill="none" stroke="{INK}" stroke-width="4.5" stroke-linecap="round"><path d="M34 49q6-8 12 0"/><path d="M54 49q6-8 12 0"/><path d="M41 56q9 11 18 0"/></g><path d="M90 3l2 5 5 2-5 2-2 5-2-5-5-2 5-2z" fill="{MINT}"/>',
 "wink": lambda c: brackets(c) + blush() + EYE(40) + f'<g fill="none" stroke="{INK}" stroke-width="4.5" stroke-linecap="round"><path d="M55 47q5 4 10 0"/><path d="M43 58q7 7 14 0"/></g>',
}
def svg(body, vb="0 0 100 100", size=512):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" width="{size}" height="{size}">{body}</svg>\n'
def w(path, text): open(path,"w").write(text)

os.makedirs("svg", exist_ok=True)
for mood, f in FACES.items():
    w(f"svg/mascot-{mood}.svg", svg(f(GRAPE)))
    w(f"svg/mascot-{mood}-badge.svg", svg(f'<rect width="100" height="100" rx="22.5" fill="{LILAC}"/><g transform="translate(11 11) scale(.78)">{f("#fff")}</g>'))
w("svg/app-icon-1024.svg", svg(f'<rect width="100" height="100" fill="{LILAC}"/>' + FACES["hi"]("#fff"), size=1024))
w("svg/app-icon-rounded.svg", svg(f'<rect width="100" height="100" rx="22.5" fill="{LILAC}"/>' + FACES["hi"]("#fff")))

# ---- wordmark: Unbounded ExtraBold (800) outlined, face as the "o" ----
font = TTFont("/home/claude/Shotsy/Shotsy/Resources/Fonts/Unbounded.ttf")
font = instancer.instantiateVariableFont(font, {"wght": 800})
gs = font.getGlyphSet(); cmap = font.getBestCmap(); upm = font["head"].unitsPerEm
xh = font["OS/2"].sxHeight
def glyph_path(ch, x):
    g = gs[cmap[ord(ch)]]
    pen = SVGPathPen(gs); g.draw(pen)
    return f'<path transform="translate({x} 0) scale(1 -1)" d="{pen.getCommands()}"/>', g.width
def wordmark(ink=INK, br=GRAPE):
    track = -0.02*upm
    parts, x = [], 0
    for ch in "sh":
        p, adv = glyph_path(ch, x); parts.append(p); x += adv + track
    face = 0.62*upm; gap = 0.04*upm
    x += gap
    # face sits on the baseline, 0.62em tall; mascot drawn in 13..87 space
    sc = face/74
    parts.append(f'<g transform="translate({x} {-face}) scale({sc}) translate(-13 -13)">' +
                 brackets(br, w=13) + f'<ellipse cx="40" cy="47" rx="6" ry="7.5" fill="{ink}"/><ellipse cx="60" cy="47" rx="6" ry="7.5" fill="{ink}"/><path d="M42.5 59q7.5 7.5 15 0" fill="none" stroke="{ink}" stroke-width="6" stroke-linecap="round"/></g>')
    x += face + gap
    for ch in "tsy":
        p, adv = glyph_path(ch, x); parts.append(p); x += adv + track
    asc, desc = 0.78*upm, 0.24*upm
    pad = 0.04*upm
    vb = f"{-pad} {-asc} {x+2*pad} {asc+desc}"
    body = f'<g fill="{ink}">' + "".join(parts) + '</g>'
    return vb, body, x, asc+desc
vb, body, W, H = wordmark()
w("svg/wordmark.svg", f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" width="{round(W/H*120)}" height="120">{body}</svg>\n')
vb2, body2, _, _ = wordmark("#ffffff", "#ffffff")
w("svg/wordmark-white.svg", f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb2}" width="{round(W/H*120)}" height="120">{body2}</svg>\n')

# horizontal lockup: rounded icon + wordmark
iconH = H*0.94
lock = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 {-0.78*upm} {iconH*1.25 + W} {H}" width="{round((iconH*1.25+W)/H*120)}" height="120">'
        f'<g transform="translate(0 {-0.78*upm + (H-iconH)/2}) scale({iconH/100})"><rect width="100" height="100" rx="22.5" fill="{LILAC}"/>{FACES["hi"]("#fff")}</g>'
        f'<g transform="translate({iconH*1.25} 0)">{body}</g></svg>\n')
w("svg/logo-lockup.svg", lock)
print(sorted(os.listdir("svg")))
