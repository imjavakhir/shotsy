#!/usr/bin/env python3
"""Composes App Store screenshots (6.9", 1320x2868) from raw simulator captures.

Each slide: brand background, localized headline + caption (from appstore/metadata/<locale>.json),
and the real app screen inside an iPhone frame. Rendered as HTML with headless Chrome, so macOS
system fonts handle Chinese/Japanese/Korean while the brand fonts handle Latin, Cyrillic, Vietnamese.

Usage: python3 tools/make_store_screenshots.py <raw-captures-dir> [locale ...]
Raw captures: <raw>/<ios-lang>/<slide-id>.png (from tools/capture_screens.sh)
Output: appstore/screenshots/<locale>/<n>_<slide-id>.png
"""
import html
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
W, H = 1320, 2868

# App Store locale -> iOS language code used for the captures.
LOCALES = {
    "en-US": "en", "ru": "ru", "es-MX": "es", "pt-BR": "pt-BR", "fr-FR": "fr", "de-DE": "de", "it": "it",
    "ja": "ja", "ko": "ko", "zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant", "id": "id", "vi": "vi",
}

CJK_FONT = {
    "ja": '"Hiragino Sans", "Hiragino Kaku Gothic ProN", sans-serif',
    "ko": '"Apple SD Gothic Neo", sans-serif',
    "zh-Hans": '"PingFang SC", sans-serif',
    "zh-Hant": '"PingFang TC", sans-serif',
}

# Per slide: flat brand background, text colors, and where the sticker callout sits (px from top, side, tilt).
# Pattern from the top photo-cleaner listings: short keyword headline, big phone, one sticker breaking the frame.
SLIDES = {
    "01-swipe": {"bg": "#5B3FD9", "fg": "#FFFFFF", "sub": "rgba(255,255,255,.8)"},
    "02-similar": {"bg": "#F5F3FC", "fg": "#1B1633", "sub": "#5B3FD9",
                   "sticker": {"top": 1330, "side": "right", "tilt": 6, "bg": "#43D9A3", "fg": "#1B1633", "icon": "star"}},
    "03-clean": {"bg": "#A794FF", "fg": "#1B1633", "sub": "#2E2560",
                 "sticker": {"top": 2390, "side": "right", "tilt": -5, "bg": "#1B1633", "fg": "#FFFFFF", "icon": "lock"}},
    "04-library": {"bg": "#F5F3FC", "fg": "#1B1633", "sub": "#5B3FD9",
                   "sticker": {"top": 1440, "side": "right", "tilt": 5, "bg": "#FFA8CF", "fg": "#1B1633", "icon": "search"}},
    "05-review": {"bg": "#1B1633", "fg": "#FFFFFF", "sub": "rgba(255,255,255,.75)",
                  "sticker": {"top": 1750, "side": "left", "tilt": -5, "bg": "#43D9A3", "fg": "#1B1633", "icon": "undo"}},
}

ICONS = {
    "check": '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
    "x": '<path d="M6 6l12 12M18 6L6 18"/>',
    "star": '<path d="M12 3.5l2.6 5.4 5.9.8-4.3 4.1 1 5.8L12 16.9l-5.2 2.7 1-5.8-4.3-4.1 5.9-.8z"/>',
    "lock": '<rect x="5" y="10.5" width="14" height="10" rx="2.5"/><path d="M8 10.5V8a4 4 0 0 1 8 0v2.5"/>',
    "search": '<circle cx="10.5" cy="10.5" r="6"/><path d="M15 15l5 5"/>',
    "undo": '<path d="M9 7L4.5 11.5 9 16"/><path d="M5 11.5h9.5a5 5 0 0 1 0 10H11"/>',
}


def sticker(text, top, side, tilt, bg, fg, icon):
    svg = ('<svg viewBox="0 0 24 24" fill="none" stroke="%s" stroke-width="2.6" stroke-linecap="round" '
           'stroke-linejoin="round">%s</svg>' % (fg, ICONS[icon]))
    return ('<div class="sticker" style="top:%dpx;%s:34px;transform:rotate(%ddeg);background:%s;color:%s">%s<span>%s</span></div>'
            % (top, side, tilt, bg, fg, svg, html.escape(text)))


TEMPLATE = """<!doctype html><html lang="{lang}"><head><meta charset="utf-8"><style>
@font-face {{ font-family: "Unbounded"; src: url("{fonts}/Unbounded-ExtraBold.ttf"); font-weight: 800; }}
@font-face {{ font-family: "Onest"; src: url("{fonts}/Onest-Medium.ttf"); font-weight: 500; }}
html, body {{ margin: 0; width: {W}px; height: {H}px; overflow: hidden; }}
body {{ background: {bg}; position: relative; -webkit-font-smoothing: antialiased; }}
.head {{ position: absolute; top: 150px; left: 80px; right: 80px; text-align: center; }}
h1 {{ margin: 0; font-family: {display}; font-weight: 800; color: {fg}; font-size: 118px; line-height: 1.08;
      letter-spacing: -1.5px; }}
p {{ margin: 34px 0 0; font-family: {text}; font-weight: 500; color: {sub}; font-size: 54px; line-height: 1.25; }}
.device {{ position: absolute; left: 50%; transform: translateX(-50%); top: 720px; width: 1080px;
           padding: 26px; background: #0E0C14; border-radius: 166px;
           box-shadow: 0 24px 60px rgba(27,22,51,.25), inset 0 0 0 4px #2C2838; }}
.device img {{ display: block; width: 100%; border-radius: 142px; }}
.sticker {{ position: absolute; display: flex; align-items: center; gap: 22px; padding: 30px 48px 30px 38px;
            border-radius: 999px; font-family: {display}; font-weight: 800; font-size: 60px; line-height: 1;
            white-space: nowrap; box-shadow: 0 18px 40px rgba(27,22,51,.28); }}
.sticker svg {{ width: 66px; height: 66px; flex: none; }}
</style></head><body>
<div class="head"><h1 id="h">{title}</h1><p>{caption}</p></div>
<div class="device" id="d"><img src="{screen}"></div>
{stickers}
<script>
// Measure after the brand fonts load, or widths come from the fallback font.
document.fonts.ready.then(() => {{
// Headline: at most 3 lines. Phone: starts under the text block and runs off the bottom edge.
const h = document.getElementById('h'); let size = 118;
while (h.getBoundingClientRect().height > size * 1.08 * 3 + 2 && size > 64) {{ size -= 4; h.style.fontSize = size + 'px'; }}
const head = document.querySelector('.head').getBoundingClientRect();
const top = Math.max(620, head.bottom + 80);
document.getElementById('d').style.top = top + 'px';
// Stickers keep their place relative to the phone, and shrink if the text is long.
for (const s of document.querySelectorAll('.sticker')) {{
  s.style.top = (parseInt(s.style.top) + top - 720) + 'px';
  let f = 60; while (s.getBoundingClientRect().width > 1060 && f > 30) {{ f -= 2; s.style.fontSize = f + 'px'; }}
}}
}});
</script>
</body></html>"""


def render(locale, lang, raw_dir, out_dir, meta):
    fonts = os.path.join(ROOT, "Shotsy/Resources/Fonts")
    cjk = CJK_FONT.get(locale)
    display = cjk or '"Unbounded", sans-serif'
    text = cjk or '"Onest", sans-serif'
    os.makedirs(out_dir, exist_ok=True)
    for n, shot in enumerate(meta["screenshots"], start=1):
        sid = shot["id"]
        screen = os.path.join(raw_dir, lang, sid + ".png")
        if not os.path.exists(screen):
            print("  missing capture", screen)
            continue
        style = SLIDES[sid]
        if sid == "01-swipe":  # "Keep|Delete": the two swipe directions, on either side of the card
            keep, delete = shot["sticker"].split("|")
            stickers = (sticker(delete, 1500, "left", -8, "#C62F52", "#FFFFFF", "x")
                        + sticker(keep, 1180, "right", 7, "#14865E", "#FFFFFF", "check"))
        else:
            st = style["sticker"]
            stickers = sticker(shot["sticker"], st["top"], st["side"], st["tilt"], st["bg"], st["fg"], st["icon"])
        page = TEMPLATE.format(
            lang=locale, fonts="file://" + fonts, W=W, H=H, bg=style["bg"], fg=style["fg"], sub=style["sub"],
            display=display, text=text, title=html.escape(shot["title"]),
            caption=html.escape(shot["caption"]), screen="file://" + screen, stickers=stickers)
        with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False) as f:
            f.write(page)
            page_path = f.name
        out = os.path.join(out_dir, "%d_%s.png" % (n, sid))
        subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--allow-file-access-from-files",
                        "--force-device-scale-factor=1", "--window-size=%d,%d" % (W, H), "--virtual-time-budget=4000",
                        "--screenshot=" + out, "file://" + page_path],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        os.unlink(page_path)
    print("rendered", locale)


def main():
    raw = sys.argv[1]
    wanted = sys.argv[2:] or list(LOCALES)
    for locale in wanted:
        meta = json.load(open(os.path.join(ROOT, "appstore/metadata/%s.json" % locale)))
        render(locale, LOCALES[locale], raw, os.path.join(ROOT, "appstore/screenshots", locale), meta)


if __name__ == "__main__":
    main()
