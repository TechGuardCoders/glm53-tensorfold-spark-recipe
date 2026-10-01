"""Build assets/hero.svg and assets/numbers.svg in the Tech Guard brand (monochrome: silver wordmark, TG halftone-ring
monogram, black). Numbers come from docs/EVALS.md; change them there first. Run: python3 assets/make_svgs.py"""
import base64, pathlib

here = pathlib.Path(__file__).parent
b64 = lambda f: base64.b64encode((here / f).read_bytes()).decode()
wordmark, monogram = b64("techguard-logo.png"), b64("techguard-tg-transparent.png")
FONT = "'Segoe UI', -apple-system, 'Helvetica Neue', Arial, sans-serif"
BLACK, CARD, MUTED, LINE = "#000000", "#0D0D0F", "#8C8C8C", "#FFFFFF"

DEFS = """<defs>
 <linearGradient id="silver" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#F4F4F4"/><stop offset="1" stop-color="#8E8E8E"/></linearGradient>
 <linearGradient id="silverH" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#DADADA"/><stop offset="1" stop-color="#7A7A7A"/></linearGradient>
 <radialGradient id="glow" cx="0.82" cy="0.5" r="0.55"><stop offset="0" stop-color="#1A1A1C"/><stop offset="1" stop-color="#000000"/></radialGradient>
</defs>"""

hero = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="360" viewBox="0 0 1280 360" role="img"
 aria-label="GLM-5.3-Flash on 2x DGX Spark: TensorFold + DFlash2 recipe by Tech Guard">
{DEFS}
<rect width="1280" height="360" rx="18" fill="url(#glow)"/>
<rect x="0.5" y="0.5" width="1279" height="359" rx="18" fill="none" stroke="{LINE}" stroke-opacity="0.10"/>
<image x="930" y="30" width="300" height="300" href="data:image/png;base64,{monogram}"/>
<image x="60" y="48" width="290" height="50" href="data:image/png;base64,{wordmark}"/>
<text x="64" y="186" font-family="{FONT}" font-size="54" font-weight="700" fill="url(#silver)">GLM-5.3-Flash on 2× DGX Spark</text>
<text x="64" y="236" font-family="{FONT}" font-size="28" font-weight="600" fill="#FFFFFF">TensorFold + DFlash2 · one-command install</text>
<text x="64" y="290" font-family="{FONT}" font-size="19" fill="{MUTED}">OpenAI-compatible API · 4 users at once · 1M-token context · tool calling · measured, not promised</text>
<rect x="64" y="314" width="120" height="3" rx="1.5" fill="url(#silverH)"/>
</svg>
'''

cards = [
    ("~100", "tok/s", "JSON &amp; structured output", "one user, streaming", "77 tok/s on code · 50 on chat"),
    ("0.44", "s", "to first word", "when an agent comes back", "to a 39k-token session (24 s cold)"),
    ("80–86", "tok/s", "4 people at once", "combined throughput", "~20–25 tok/s each, nobody waits"),
    ("2.3×", "", "faster than our old build", "same Sparks, same weights", "vLLM 21–23 → 49–53 tok/s chat"),
]
W, H, PAD, GAP = 1280, 400, 64, 24
cw = (W - 2 * PAD - 3 * GAP) / 4
body = ""
for i, (big, unit, l1, l2, sub) in enumerate(cards):
    x = PAD + i * (cw + GAP); y = 92
    body += f'''<g transform="translate({x:.1f},{y})">
 <rect width="{cw:.1f}" height="260" rx="16" fill="{CARD}" stroke="{LINE}" stroke-opacity="0.14"/>
 <text x="24" y="92" font-family="{FONT}" font-size="{64 if len(big) <= 4 else 54}" font-weight="800" fill="url(#silver)">{big}<tspan font-size="26" font-weight="600" fill="#BDBDBD" dx="8">{unit}</tspan></text>
 <text x="24" y="146" font-family="{FONT}" font-size="21" font-weight="700" fill="#FFFFFF">{l1}</text>
 <text x="24" y="174" font-family="{FONT}" font-size="18" fill="{MUTED}">{l2}</text>
 <line x1="24" y1="200" x2="{cw - 24:.1f}" y2="200" stroke="{LINE}" stroke-opacity="0.12"/>
 <text x="24" y="232" font-family="{FONT}" font-size="16" fill="{MUTED}">{sub}</text>
</g>'''
numbers = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img"
 aria-label="About 100 tokens per second on JSON and structured output; 0.44 seconds to first word on a returning agent session; 80 to 86 tokens per second for 4 people at once; 2.3 times faster than our previous vLLM build">
{DEFS}
<rect width="{W}" height="{H}" rx="18" fill="{BLACK}"/>
<rect x="0.5" y="0.5" width="{W - 1}" height="{H - 1}" rx="18" fill="none" stroke="{LINE}" stroke-opacity="0.10"/>
<text x="{PAD}" y="58" font-family="{FONT}" font-size="15" font-weight="700" letter-spacing="3" fill="#D9D9D9">THE NUMBERS YOU FEEL</text>
<text x="{W - PAD}" y="58" text-anchor="end" font-family="{FONT}" font-size="15" fill="{MUTED}">2x DGX Spark · base GLM-5.3-Flash EXL3 4-bit · stock OS</text>
{body}
</svg>
'''
(here / "hero.svg").write_text(hero, encoding="utf-8", newline="\n")
(here / "numbers.svg").write_text(numbers, encoding="utf-8", newline="\n")
print("wrote hero.svg, numbers.svg")
