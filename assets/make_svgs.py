"""Build assets/hero.svg and assets/numbers.svg (Tech Guard branding: gold #E8C84A on navy #080E22).
Numbers come from docs/EVALS.md; change them there first. Run: python3 assets/make_svgs.py"""
import base64, pathlib

here = pathlib.Path(__file__).parent
logo = base64.b64encode((here / "techguard-logo.png").read_bytes()).decode()
FONT = "'Segoe UI', -apple-system, 'Helvetica Neue', Arial, sans-serif"
GOLD, GOLD2, NAVY, NAVY2, MUTED = "#E8C84A", "#B89830", "#080E22", "#0F1B3D", "#9FA5BF"

def hexagon(cx, cy, r):
    import math
    pts = [(cx + r * math.cos(math.radians(60 * i)), cy + r * math.sin(math.radians(60 * i))) for i in range(6)]
    return " ".join(f"{x:.1f},{y:.1f}" for x, y in pts)

hexes = "".join(f'<polygon points="{hexagon(x, y, 46)}" fill="none" stroke="{GOLD}" stroke-opacity="{o}" stroke-width="1.2"/>'
                for x, y, o in [(1080, 90, .22), (1160, 136, .14), (1160, 228, .10), (1080, 274, .16), (1000, 228, .08),
                                (1240, 90, .07), (1000, 136, .12), (1240, 274, .05)])

hero = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="360" viewBox="0 0 1280 360" role="img"
 aria-label="GLM-5.3-Flash on 2x DGX Spark: TensorFold + DFlash2 recipe by Tech Guard">
<defs>
 <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{NAVY}"/><stop offset="1" stop-color="{NAVY2}"/></linearGradient>
 <linearGradient id="gold" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#F4E28A"/><stop offset="1" stop-color="{GOLD}"/></linearGradient>
</defs>
<rect width="1280" height="360" rx="18" fill="url(#bg)"/>
{hexes}
<image x="64" y="44" width="230" height="71" href="data:image/png;base64,{logo}"/>
<text x="64" y="186" font-family="{FONT}" font-size="54" font-weight="700" fill="#FFFFFF">GLM-5.3-Flash on 2× DGX Spark</text>
<text x="64" y="236" font-family="{FONT}" font-size="28" font-weight="600" fill="url(#gold)">TensorFold + DFlash2 · one-command install</text>
<text x="64" y="290" font-family="{FONT}" font-size="19" fill="{MUTED}">OpenAI-compatible API · 4 users at once · 1M-token context · tool calling · measured, not promised</text>
<rect x="64" y="314" width="120" height="4" rx="2" fill="{GOLD}"/>
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
 <rect width="{cw:.1f}" height="260" rx="16" fill="#FFFFFF" fill-opacity="0.035" stroke="{GOLD}" stroke-opacity="0.35"/>
 <text x="24" y="92" font-family="{FONT}" font-size="{64 if len(big) <= 4 else 54}" font-weight="800" fill="url(#gold)">{big}<tspan font-size="26" font-weight="600" fill="{GOLD}" dx="8">{unit}</tspan></text>
 <text x="24" y="146" font-family="{FONT}" font-size="21" font-weight="700" fill="#FFFFFF">{l1}</text>
 <text x="24" y="174" font-family="{FONT}" font-size="18" fill="{MUTED}">{l2}</text>
 <line x1="24" y1="200" x2="{cw - 24:.1f}" y2="200" stroke="{GOLD}" stroke-opacity="0.18"/>
 <text x="24" y="232" font-family="{FONT}" font-size="16" fill="{MUTED}">{sub}</text>
</g>'''
numbers = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img"
 aria-label="About 100 tokens per second on JSON and structured output; 0.44 seconds to first word on a returning agent session; 80 to 86 tokens per second for 4 people at once; 2.3 times faster than our previous vLLM build">
<defs>
 <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{NAVY}"/><stop offset="1" stop-color="{NAVY2}"/></linearGradient>
 <linearGradient id="gold" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#F4E28A"/><stop offset="1" stop-color="{GOLD}"/></linearGradient>
</defs>
<rect width="{W}" height="{H}" rx="18" fill="url(#bg)"/>
<text x="{PAD}" y="58" font-family="{FONT}" font-size="15" font-weight="700" letter-spacing="3" fill="{GOLD}">THE NUMBERS YOU FEEL</text>
<text x="{W - PAD}" y="58" text-anchor="end" font-family="{FONT}" font-size="15" fill="{MUTED}">2x DGX Spark · base GLM-5.3-Flash EXL3 4-bit · stock OS</text>
{body}
</svg>
'''
(here / "hero.svg").write_text(hero, encoding="utf-8", newline="\n")
(here / "numbers.svg").write_text(numbers, encoding="utf-8", newline="\n")
print("wrote hero.svg, numbers.svg")
