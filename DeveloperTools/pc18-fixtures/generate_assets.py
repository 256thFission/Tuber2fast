#!/usr/bin/env python3
"""Generate deterministic, fixture-only PC-18 pages. No product/runtime imports."""
from pathlib import Path

ROOT = Path(__file__).resolve().parent
ASSETS = ROOT / "assets"

SVG_HEAD = '''<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="800" viewBox="0 0 1200 800">
<rect width="1200" height="800" fill="#fffdf8"/><style>text{fill:#182033;font-family:Helvetica,Arial,sans-serif}.ink{font-family:"Marker Felt","Comic Sans MS",cursive}.small{font-size:30px}.main{font-size:54px}.title{font-size:34px;font-weight:bold}.arrow{fill:none;stroke:#182033;stroke-width:6;stroke-linecap:round}</style>'''

def svg(name, body):
    (ASSETS / name).write_text(SVG_HEAD + body + "\n</svg>\n", encoding="utf-8")

def calc(name, lines, blur=False):
    body = '<text x="110" y="110" class="title ink">Calc I — Check the selected work</text>'
    for i, line in enumerate(lines):
        attrs = ' opacity="0.22" filter="url(#blur)"' if blur and i == 0 else ''
        body += f'<text x="150" y="{230+i*115}" class="main ink"{attrs}>{line}</text>'
    if blur:
        body = '<defs><filter id="blur"><feGaussianBlur stdDeviation="9"/></filter></defs>' + body
    svg(name, body)

def curved(x1,y1,cx,cy,x2,y2,head=True):
    marker = ' marker-end="url(#head)"' if head else ''
    return f'<path d="M{x1} {y1} Q{cx} {cy} {x2} {y2}" class="arrow"{marker}/>'

def chem(name, title, equation, arrows="", extra=""):
    defs = '<defs><marker id="head" markerWidth="12" markerHeight="12" refX="9" refY="5" orient="auto"><path d="M0,0 L10,5 L0,10 Z" fill="#182033"/></marker></defs>'
    svg(name, defs + f'<text x="80" y="100" class="title">{title}</text><text x="100" y="430" class="main">{equation}</text>' + arrows + extra)

def pdf_escape(s): return s.replace('\\','\\\\').replace('(','\\(').replace(')','\\)')

def make_sn2_pdf():
    # Vector PDF: text plus two curved Bezier arrows with filled arrowheads.
    stream = "\n".join([
        "1 1 0.97 rg 0 0 792 612 re f", "0.09 0.13 0.20 rg",
        "BT /F1 22 Tf 54 535 Td (Intro Ochem - Explain electron flow) Tj ET",
        "BT /F1 29 Tf 62 270 Td (HO) Tj ET", "BT /F1 16 Tf 102 284 Td (-) Tj ET",
        "BT /F1 29 Tf 128 270 Td (+  CH) Tj ET", "BT /F1 16 Tf 220 260 Td (3) Tj ET",
        "BT /F1 29 Tf 230 270 Td (CH) Tj ET", "BT /F1 16 Tf 275 260 Td (2) Tj ET",
        "BT /F1 29 Tf 286 270 Td (-Br  ->  CH) Tj ET", "BT /F1 16 Tf 440 260 Td (3) Tj ET",
        "BT /F1 29 Tf 450 270 Td (CH) Tj ET", "BT /F1 16 Tf 495 260 Td (2) Tj ET",
        "BT /F1 29 Tf 506 270 Td (-OH  +  Br) Tj ET", "BT /F1 16 Tf 650 284 Td (-) Tj ET",
        "0.09 0.13 0.20 RG 3 w 90 315 m 150 400 250 400 327 316 c S",
        "327 316 m 312 323 l 319 337 l f",
        "390 316 m 455 395 520 395 585 317 c S",
        "585 317 m 569 323 l 577 338 l f"
    ]).encode("ascii")
    objs = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 792 612] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
        b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    ]
    out = bytearray(b"%PDF-1.4\n%PC18\n"); offsets = [0]
    for i,obj in enumerate(objs,1): offsets.append(len(out)); out += f"{i} 0 obj\n".encode()+obj+b"\nendobj\n"
    xref=len(out); out += f"xref\n0 {len(objs)+1}\n0000000000 65535 f \n".encode()
    for off in offsets[1:]: out += f"{off:010d} 00000 n \n".encode()
    out += f"trailer << /Size {len(objs)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    (ASSETS / "O1-golden-sn2.pdf").write_bytes(out)

def main():
    ASSETS.mkdir(exist_ok=True)
    calc("C1-golden-missing-half.svg", ["∫ x e^(x²) dx", "u = x²      du = 2x dx", "∫ eᵘ du", "e^(x²) + C"])
    calc("C2-corrected-golden.svg", ["∫ x e^(x²) dx", "u = x²      du = 2x dx", "½ ∫ eᵘ du", "½e^(x²) + C"])
    calc("C3-missing-constant.svg", ["∫ x e^(x²) dx", "u = x²      du = 2x dx", "½ ∫ eᵘ du", "½e^(x²)"])
    calc("C4-power-rule-correct.svg", ["∫ x³ dx", "= x⁴/4 + C"])
    calc("C5-unreadable-exponent.svg", ["∫ x e^(x ?) dx", "u = x ?"], blur=True)
    calc("C6-integration-by-parts.svg", ["∫ x eˣ dx", "u=x    dv=eˣdx", "= x eˣ − ∫ eˣ dx", "= eˣ(x−1) + C"])
    a1=curved(170,350,270,160,465,345)+curved(570,345,670,160,770,345)
    chem("O1-golden-sn2.svg","Canonical SN2 reaction","HO⁻ + CH₃CH₂—Br   →   CH₃CH₂—OH + Br⁻",a1)
    a2=curved(170,350,270,160,465,345,False)+curved(570,345,670,160,770,345,False)
    chem("O2-sn2-no-arrowheads.svg","Reaction diagram","HO⁻ + CH₃CH₂—Br   →   CH₃CH₂—OH + Br⁻",a2)
    chem("O3-cropped-leaving-group.svg","Reaction diagram","HO⁻ + CH₃CH₂—",curved(170,350,270,160,465,345))
    chem("O4-label-only.svg","Example 7: Nucleophilic substitution","","")
    a5=curved(170,350,250,170,465,345)+curved(570,345,650,170,790,345)
    chem("O5-proton-transfer.svg","Proton transfer",":B⁻ + H—A   →   H—B + A⁻",a5)
    wedge='<path d="M390 430 L500 355 L500 505 Z" fill="#182033"/><path d="M520 370 L610 345 M520 395 L595 380 M520 420 L580 415 M520 445 L565 450" class="arrow"/>'
    chem("O6-wedge-dash.svg","Assign stereochemistry","R—C*—X",'',wedge)
    make_sn2_pdf()

if __name__ == "__main__": main()
