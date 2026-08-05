#!/usr/bin/env python3
"""Render the README charts from the committed logs in report/.

Emits a light and a dark SVG per chart into docs/; the README selects between them
with <picture media="(prefers-color-scheme: dark)">. Standard library only - the
benchmark scripts stay pure bash so they need nothing but adb, but this is a
build-time tool and four charts sharing a layout are far clearer here than in awk.

Colours are the validated categorical slots with their own dark-surface steps, not
an automatic flip. Slots 1-3 clear the all-pairs CVD, normal-vision and contrast
gates in both modes; aqua sits just under 3:1 on the light surface, which is why
every mark it carries also has a visible text label.

Usage: tools/mk-charts.py [report-dir] [out-dir]
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPORT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "report")
DOCS = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "docs")

FONT = "system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif"

THEMES = {
    "light": dict(surface="#fcfcfb", s1="#2a78d6", s2="#eb6834", s3="#1baf7a",
                  ink="#0b0b0b", ink2="#52514e", muted="#898781",
                  grid="#e1e0d9", axis="#c3c2b7"),
    "dark":  dict(surface="#1a1a19", s1="#3987e5", s2="#d95926", s3="#199e70",
                  ink="#ffffff", ink2="#c3c2b7", muted="#898781",
                  grid="#2c2c2a", axis="#383835"),
}


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def head(w, h, t, aria):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" '
            f'width="{w}" height="{h}" font-family="{FONT}" role="img" '
            f'aria-label="{esc(aria)}">\n'
            f'<rect width="{w}" height="{h}" fill="{t["surface"]}"/>\n')


def titles(x, t, title, subtitle):
    out = (f'<text x="{x}" y="32" fill="{t["ink"]}" font-size="17" '
           f'font-weight="600">{esc(title)}</text>\n')
    if subtitle:
        out += (f'<text x="{x}" y="54" fill="{t["ink2"]}" font-size="12.5">'
                f'{esc(subtitle)}</text>\n')
    return out


# --------------------------------------------------------------- data loading

def load_sweep(path):
    """[(model, MHz, ms)] for every pinned --sweep row."""
    rows, model = [], None
    for line in open(path):
        if line.startswith("--- "):
            model = line.split()[1]
        m = re.match(r"\s+(\d+)\s+([\d.]+)\s+\d+\s", line)
        if m and model:
            rows.append((model, int(m.group(1)) / 1000, float(m.group(2))))
    return rows


def load_rows(path, col):
    """{(model, backend): value} from a bench table, value taken from column `col`."""
    out, model = {}, None
    for line in open(path):
        if line.startswith("--- "):
            model = line.split()[1]
        m = re.match(r"(cpu-\d+thr|gpu-adaptive|gpu-pinned|edgetpu)\s+([\d.]+)\s+([\d.]+)", line)
        if m and model:
            out[(model, m.group(1))] = float(m.group(col))
    return out


# ------------------------------------------------------------- chart: h-bars

def wrap(text, px_wide, size=11.5):
    """Greedy wrap at an estimated glyph width - SVG has no auto-wrapping, and an
    over-long note silently runs off the right edge."""
    per = size * 0.5
    out, line = [], ""
    for word in text.split():
        trial = (line + " " + word).strip()
        if len(trial) * per > px_wide and line:
            out.append(line)
            line = word
        else:
            line = trial
    if line:
        out.append(line)
    return out


def hbar(t, title, subtitle, rows, unit, aria, ref=None, note=None, width=800,
         fmt="{:.2f}"):
    """rows: [(label, value)]. One series, one colour - the categories are nominal,
    so shading by magnitude would double-encode the bar length."""
    left, right, top = 208, width - 96, 84
    bar_h, gap = 26, 16
    note_lines = wrap(note, width - (left - 146) - 24) if note else []
    h = top + len(rows) * (bar_h + gap) + 26 + len(note_lines) * 17
    vmax = max([v for _, v in rows] + ([ref[0]] if ref else [])) * 1.08

    def px(v):
        return left + v * (right - left) / vmax

    o = head(width, h, t, aria) + titles(left - 146, t, title, subtitle)

    if ref:
        x = px(ref[0])
        o += (f'<line x1="{x:.1f}" y1="{top - 10}" x2="{x:.1f}" '
              f'y2="{top + len(rows) * (bar_h + gap) - gap + 4}" '
              f'stroke="{t["axis"]}" stroke-width="1.5"/>\n')
        o += (f'<text x="{x + 7:.1f}" y="{top - 14}" fill="{t["ink2"]}" '
              f'font-size="11.5">{esc(ref[1])}</text>\n')

    y = top
    for label, v in rows:
        o += (f'<rect x="{left}" y="{y}" width="{px(v) - left:.1f}" height="{bar_h}" '
              f'rx="4" fill="{t["s1"]}"/>\n')
        o += (f'<text x="{left - 12}" y="{y + bar_h / 2 + 4:.0f}" fill="{t["ink2"]}" '
              f'font-size="12.5" text-anchor="end">{esc(label)}</text>\n')
        o += (f'<text x="{px(v) + 10:.1f}" y="{y + bar_h / 2 + 4:.0f}" fill="{t["ink"]}" '
              f'font-size="12.5" font-weight="600" '
              f'style="font-variant-numeric:tabular-nums">{fmt.format(v)} {esc(unit)}</text>\n')
        y += bar_h + gap

    ny = h - 14 - (len(note_lines) - 1) * 17
    for line in note_lines:
        o += (f'<text x="{left - 146}" y="{ny}" fill="{t["muted"]}" '
              f'font-size="11.5">{esc(line)}</text>\n')
        ny += 17
    return o + "</svg>\n"


# -------------------------------------------------------------- chart: sweep

def sweep_chart(t, data):
    W, H = 800, 432
    L, R, T, B = 84, 596, 74, 348
    XMIN, XMAX, YMIN, YMAX = 150, 890, 0, 25
    STOCK = 208

    def px(mhz):
        return L + (mhz - XMIN) * (R - L) / (XMAX - XMIN)

    def py(ms):
        return B - (ms - YMIN) * (B - T) / (YMAX - YMIN)

    series = {}
    for model, mhz, ms in data:
        series.setdefault(model, []).append((mhz, ms))
    names = sorted(series, key=lambda m: "quant" in m)   # float32 first
    colours = [t["s1"], t["s2"]]

    o = head(W, H, t,
             "Inference latency against GPU clock for MobileNet v1 224, float32 and "
             "int8, across all 13 DVFS steps. Latency falls from about 21-24 ms at "
             "150 MHz to about 6-7 ms at 890 MHz and flattens above roughly 580 MHz. "
             "A marker at 208 MHz shows where the stock governor leaves the GPU.")
    o += titles(L - 22, t, "Mali-G715 inference latency vs GPU clock",
                "MobileNet v1 224 through the TFLite GPU delegate (OpenCL) "
                "· Pixel 8, clock pinned at each of the 13 DVFS steps")

    for v in range(YMIN, YMAX + 1, 5):
        o += (f'<line x1="{L}" y1="{py(v):.1f}" x2="{R}" y2="{py(v):.1f}" '
              f'stroke="{t["axis"] if v == YMIN else t["grid"]}" stroke-width="1"/>\n')
        o += (f'<text x="{L - 10}" y="{py(v) + 4:.1f}" fill="{t["muted"]}" '
              f'font-size="11.5" text-anchor="end" '
              f'style="font-variant-numeric:tabular-nums">{v}</text>\n')
    o += (f'<text transform="rotate(-90)" x="{-(T + B) / 2:.1f}" y="22" '
          f'fill="{t["muted"]}" font-size="11.5" text-anchor="middle">latency (ms)</text>\n')

    for tick in (150, 300, 450, 600, 750, 890):
        o += (f'<line x1="{px(tick):.1f}" y1="{B}" x2="{px(tick):.1f}" y2="{B + 5}" '
              f'stroke="{t["axis"]}" stroke-width="1"/>\n')
        o += (f'<text x="{px(tick):.1f}" y="{B + 22}" fill="{t["muted"]}" '
              f'font-size="11.5" text-anchor="middle" '
              f'style="font-variant-numeric:tabular-nums">{tick}</text>\n')
    o += (f'<text x="{(L + R) / 2:.1f}" y="{B + 44}" fill="{t["muted"]}" '
          f'font-size="11.5" text-anchor="middle">GPU clock (MHz)</text>\n')

    # where the stock governor actually leaves the GPU
    o += (f'<line x1="{px(STOCK):.1f}" y1="{T}" x2="{px(STOCK):.1f}" y2="{B}" '
          f'stroke="{t["axis"]}" stroke-width="1.5"/>\n')
    o += (f'<text x="{px(STOCK) + 8:.1f}" y="{T + 14}" fill="{t["ink2"]}" '
          f'font-size="11.5">stock governor sits here</text>\n')
    o += (f'<text x="{px(STOCK) + 8:.1f}" y="{T + 30}" fill="{t["muted"]}" '
          f'font-size="11.5">(208 MHz effective, 23% of peak)</text>\n')

    label_y = {}
    for i, name in enumerate(names):
        pts = sorted(series[name], key=lambda p: -p[0])
        o += (f'<polyline fill="none" stroke="{colours[i]}" stroke-width="2" '
              f'stroke-linejoin="round" stroke-linecap="round" points="'
              + " ".join(f"{px(m):.1f},{py(v):.1f}" for m, v in pts) + '"/>\n')
        for m, v in pts:
            o += (f'<circle cx="{px(m):.1f}" cy="{py(v):.1f}" r="4" '
                  f'fill="{colours[i]}" stroke="{t["surface"]}" stroke-width="2"/>\n')
        label_y[i] = py(pts[0][1]) + 4

    # the series converge at the top clock; push labels apart to a line height
    if len(names) == 2 and abs(label_y[0] - label_y[1]) < 18:
        lo, hi = (0, 1) if label_y[0] < label_y[1] else (1, 0)
        push = (18 - abs(label_y[0] - label_y[1])) / 2
        label_y[lo] -= push
        label_y[hi] += push

    for i, name in enumerate(names):
        top_ms = sorted(series[name], key=lambda p: -p[0])[0][1]
        tag = "int8" if "quant" in name else "float32"
        o += (f'<text x="{R + 12}" y="{label_y[i]:.1f}" font-size="12.5">'
              f'<tspan fill="{colours[i]}" font-weight="600">{tag}</tspan>'
              f'<tspan dx="7" fill="{t["muted"]}" '
              f'style="font-variant-numeric:tabular-nums">{top_ms:.2f} ms</tspan></text>\n')

    lx, ly = L - 22, H - 16
    for i, name in enumerate(names):
        tag = "int8" if "quant" in name else "float32"
        o += f'<circle cx="{lx + 5}" cy="{ly - 4}" r="4" fill="{colours[i]}"/>\n'
        o += (f'<text x="{lx + 16}" y="{ly}" fill="{t["ink2"]}" '
              f'font-size="12">{tag}</text>\n')
        lx += 92
    o += (f'<text x="{R}" y="{ly}" fill="{t["muted"]}" font-size="11.5" '
          f'text-anchor="end">lower is better</text>\n')
    return o + "</svg>\n"


# --------------------------------------------------------------------- build

def write(name, fn):
    os.makedirs(DOCS, exist_ok=True)
    for mode, t in THEMES.items():
        with open(os.path.join(DOCS, f"{name}-{mode}.svg"), "w") as f:
            f.write(fn(t))
    print(f"  {name}-{{light,dark}}.svg")


MODEL = "mobilenet_v1_1.0_224_quant.tflite"

npu = load_rows(os.path.join(REPORT, "npu.log"), 3)      # col 3 = INFER(ms)
gpu = load_rows(os.path.join(REPORT, "gpu-modes.log"), 2)  # col 2 = INFER(ms)
sweep = load_sweep(os.path.join(REPORT, "gpu.log"))
tpu_ms = npu[(MODEL, "edgetpu")]

print("writing charts to", DOCS)

# One unit, one variable. The NPU does not vary with GPU clock, so it belongs
# in the cross-unit `backends` chart rather than on this axis.
write("gpu-sweep", lambda t: sweep_chart(t, sweep))

write("backends", lambda t: hbar(
    t, "One model, five ways to run it",
    "MobileNet v1 224 int8 · Pixel 8 · mean inference latency",
    [("CPU, 1 thread", round(npu[(MODEL, "cpu-1thr")], 2)),
     ("GPU, stock governor", round(gpu[(MODEL, "gpu-adaptive")], 2)),
     ("CPU, 8 threads", round(npu[(MODEL, "cpu-8thr")], 2)),
     ("GPU, pinned 890 MHz", round(gpu[(MODEL, "gpu-pinned")], 2)),
     ("EdgeTPU via NNAPI", round(tpu_ms, 2))],
    "ms",
    "Mean inference latency for MobileNet v1 224 int8 on five backends: CPU one "
    "thread 33.98 ms, GPU on the stock governor 23.88, CPU eight threads 20.71, "
    "GPU pinned to 890 MHz 7.79, and the EdgeTPU 1.00 ms.",
    fmt="{:.2f}",
    note="The EdgeTPU also costs 1.1-2.1 s of one-time graph compilation, which is "
         "usually what decides whether offloading pays off."))

# From the counter-multiplexing experiment documented in cpu-bench.sh's header:
# cpu8 pinned, scaling_cur_freq confirming 2.914 GHz, event count varied.
write("multiplex", lambda t: hbar(
    t, "simpleperf deflates the clock past three hardware events",
    "Cortex-X3 pinned, scaling_cur_freq confirming 2.914 GHz throughout",
    [("3 events", 2.916), ("4 events", 2.073), ("5 events", 1.679), ("6 events", 1.355)],
    "GHz",
    "Reported CPU clock against the number of hardware events counted, on a core "
    "held at a verified 2.914 GHz: three events report 2.916 GHz, four report "
    "2.073, five report 1.679, six report 1.355.",
    ref=(2.914, "true clock, 2.914 GHz"), fmt="{:.3f}",
    note="Counter multiplexing, unscaled: task-clock keeps running while the hardware "
         "counters rotate out, so every rate against it is quietly deflated."))

# Residency of one unpinned run, from the measurement in gpu-bench.sh's header.
write("gpu-residency", lambda t: hbar(
    t, "Where the stock GPU governor actually spends a run",
    "Time at each DVFS step across one unpinned MobileNet run · 890 MHz is available "
    "and never used",
    [("150 MHz (the floor)", 1204), ("302 MHz", 319), ("337 MHz", 162), ("376 MHz", 116)],
    "ms",
    "Time spent at each GPU frequency during one unpinned run: 1204 ms at the "
    "150 MHz floor, 319 ms at 302 MHz, 162 ms at 337 MHz and 116 ms at 376 MHz. "
    "Nothing above 376 MHz.",
    fmt="{:.0f}",
    note="1801 ms total, an effective 208 MHz against an 890 MHz peak - 23%."))
