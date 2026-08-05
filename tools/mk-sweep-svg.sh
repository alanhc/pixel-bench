#!/usr/bin/env bash
#
# mk-sweep-svg.sh - render the GPU DVFS sweep in a gpu.log as a pair of SVG charts,
# one stepped for a light surface and one for dark. GitHub picks between them with
# <picture media="(prefers-color-scheme: dark)">.
#
# Usage: tools/mk-sweep-svg.sh [gpu.log] [outdir]
#        defaults: report/gpu.log docs/
#
# Colours are the validated categorical slots 1 and 2 (blue, orange) with their own
# dark-surface steps - not an automatic flip. Both sets pass the all-pairs CVD,
# normal-vision and contrast gates on their respective surfaces.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="${1:-$ROOT/report/gpu.log}"
OUT="${2:-$ROOT/docs}"

[[ -s "$LOG" ]] || { echo "no sweep log at $LOG" >&2; exit 1; }
mkdir -p "$OUT"

# "<model> <kHz> <ms>" for every pinned sweep row
DATA=$(awk '/^--- /{m=$2} /^ *[0-9]+ +[0-9.]+ +[0-9]+ /{print m, $1, $2}' "$LOG")
[[ -n "$DATA" ]] || { echo "$LOG has no --sweep rows; run gpu-bench.sh --sweep" >&2; exit 1; }

render() { # render <mode> <surface> <s1> <s2> <ink> <ink2> <muted> <grid> <axis>
	awk -v mode="$1" -v surface="$2" -v s1="$3" -v s2="$4" \
	    -v ink="$5" -v ink2="$6" -v muted="$7" -v grid="$8" -v axis="$9" '
	BEGIN {
		W = 800; H = 432
		L = 84; R = 596; T = 74; B = 348        # plot rect
		XMIN = 150; XMAX = 890                  # MHz
		YMIN = 0;   YMAX = 25                   # ms
		STOCK = 208                             # measured stock-governor effective clock
		# Single quotes inside: this string lands in a double-quoted XML attribute,
		# and nested double quotes make the whole SVG unparseable.
		FONT = "system-ui, -apple-system, '\''Segoe UI'\'', Roboto, sans-serif"
	}
	function px(mhz) { return L + (mhz - XMIN) * (R - L) / (XMAX - XMIN) }
	function py(ms)  { return B - (ms - YMIN) * (B - T) / (YMAX - YMIN) }
	function esc(s)  { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); return s }

	{ mhz = $2 / 1000
	  if (!($1 in idx)) { idx[$1] = ++nseries; name[nseries] = $1 }
	  i = idx[$1]; n[i]++; X[i, n[i]] = mhz; Y[i, n[i]] = $3 }

	END {
		# Slot 1 is the float32 graph, slot 2 the int8 one; label them by precision
		# rather than filename - the filenames are long and the axis carries the rest.
		for (i = 1; i <= nseries; i++)
			label[i] = (name[i] ~ /quant/) ? "int8" : "float32"
		col[1] = s1; col[2] = s2

		printf "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 %d %d\" width=\"%d\" height=\"%d\" font-family=\"%s\" role=\"img\" aria-label=\"Mali-G715 inference latency against GPU clock: latency falls from about 22 ms at 150 MHz to about 6 ms at 890 MHz, with diminishing returns above 580 MHz.\">\n", W, H, W, H, FONT
		printf "<rect width=\"%d\" height=\"%d\" fill=\"%s\"/>\n", W, H, surface

		# --- titles
		printf "<text x=\"%d\" y=\"32\" fill=\"%s\" font-size=\"17\" font-weight=\"600\">Mali-G715 inference latency vs GPU clock</text>\n", L - 22, ink
		printf "<text x=\"%d\" y=\"54\" fill=\"%s\" font-size=\"12.5\">MobileNet v1 224 through the TFLite GPU delegate (OpenCL) &#183; Pixel 8, clock pinned at each of the 13 DVFS steps</text>\n", L - 22, ink2

		# --- y grid + labels (solid hairlines, one shade off the surface)
		for (v = YMIN; v <= YMAX; v += 5) {
			printf "<line x1=\"%d\" y1=\"%.1f\" x2=\"%d\" y2=\"%.1f\" stroke=\"%s\" stroke-width=\"1\"/>\n", L, py(v), R, py(v), (v == YMIN ? axis : grid)
			printf "<text x=\"%d\" y=\"%.1f\" fill=\"%s\" font-size=\"11.5\" text-anchor=\"end\" style=\"font-variant-numeric:tabular-nums\">%d</text>\n", L - 10, py(v) + 4, muted, v
		}
		# Rotated axis title rather than a floating unit at the top left, which collided
		# with the subtitle.
		printf "<text transform=\"rotate(-90)\" x=\"%.1f\" y=\"22\" fill=\"%s\" font-size=\"11.5\" text-anchor=\"middle\">latency (ms)</text>\n", -(T + B) / 2, muted

		# --- x ticks
		split("150 300 450 600 750 890", xt, " ")
		for (k = 1; k <= 6; k++) {
			printf "<line x1=\"%.1f\" y1=\"%d\" x2=\"%.1f\" y2=\"%d\" stroke=\"%s\" stroke-width=\"1\"/>\n", px(xt[k]), B, px(xt[k]), B + 5, axis
			printf "<text x=\"%.1f\" y=\"%d\" fill=\"%s\" font-size=\"11.5\" text-anchor=\"middle\" style=\"font-variant-numeric:tabular-nums\">%d</text>\n", px(xt[k]), B + 22, muted, xt[k]
		}
		printf "<text x=\"%.1f\" y=\"%d\" fill=\"%s\" font-size=\"11.5\" text-anchor=\"middle\">GPU clock (MHz)</text>\n", (L + R) / 2, B + 44, muted

		# --- stock-governor annotation: the whole point of pinning
		printf "<line x1=\"%.1f\" y1=\"%d\" x2=\"%.1f\" y2=\"%d\" stroke=\"%s\" stroke-width=\"1.5\"/>\n", px(STOCK), T, px(STOCK), B, axis
		printf "<text x=\"%.1f\" y=\"%d\" fill=\"%s\" font-size=\"11.5\">stock governor sits here</text>\n", px(STOCK) + 8, T + 14, ink2
		printf "<text x=\"%.1f\" y=\"%d\" fill=\"%s\" font-size=\"11.5\">(208 MHz effective, 23%% of peak)</text>\n", px(STOCK) + 8, T + 30, muted

		# --- series
		for (i = 1; i <= nseries; i++) {
			printf "<polyline fill=\"none\" stroke=\"%s\" stroke-width=\"2\" stroke-linejoin=\"round\" stroke-linecap=\"round\" points=\"", col[i]
			for (j = 1; j <= n[i]; j++) printf "%.1f,%.1f ", px(X[i, j]), py(Y[i, j])
			printf "\"/>\n"
			for (j = 1; j <= n[i]; j++)
				printf "<circle cx=\"%.1f\" cy=\"%.1f\" r=\"4\" fill=\"%s\" stroke=\"%s\" stroke-width=\"2\"/>\n", px(X[i, j]), py(Y[i, j]), col[i], surface
			ly[i] = py(Y[i, 1]) + 4       # sweep rows are emitted top-clock first
		}

		# Direct labels sit at the top clock, so identity never rests on colour alone.
		# The series converge there, so push apart any pair closer than a line height.
		for (a = 1; a <= nseries; a++)
			for (b = a + 1; b <= nseries; b++) {
				gap = ly[b] - ly[a]
				if (gap >= 0 && gap < 18) { ly[a] -= (18 - gap) / 2; ly[b] += (18 - gap) / 2 }
				else if (gap < 0 && -gap < 18) { ly[b] -= (18 + gap) / 2; ly[a] += (18 + gap) / 2 }
			}

		for (i = 1; i <= nseries; i++)
			printf "<text x=\"%.1f\" y=\"%.1f\" font-size=\"12.5\"><tspan fill=\"%s\" font-weight=\"600\">%s</tspan><tspan dx=\"7\" fill=\"%s\" style=\"font-variant-numeric:tabular-nums\">%.2f ms</tspan></text>\n", px(X[i, 1]) + 12, ly[i], col[i], label[i], muted, Y[i, 1]

		# --- legend (always present for two or more series)
		lx = L - 22; legy = H - 16      # `ly` is the label array above; awk forbids reuse
		for (i = 1; i <= nseries; i++) {
			printf "<circle cx=\"%.1f\" cy=\"%.1f\" r=\"4\" fill=\"%s\"/>\n", lx + 5, legy - 4, col[i]
			printf "<text x=\"%.1f\" y=\"%.1f\" fill=\"%s\" font-size=\"12\">%s</text>\n", lx + 16, legy, ink2, label[i]
			lx += 92
		}
		printf "<text x=\"%d\" y=\"%.1f\" fill=\"%s\" font-size=\"11.5\" text-anchor=\"end\">lower is better</text>\n", R, legy, muted
		printf "</svg>\n"
	}'
}

render light "#fcfcfb" "#2a78d6" "#eb6834" "#0b0b0b" "#52514e" "#898781" "#e1e0d9" "#c3c2b7" <<<"$DATA" >"$OUT/gpu-sweep-light.svg"
render dark  "#1a1a19" "#3987e5" "#d95926" "#ffffff" "#c3c2b7" "#898781" "#2c2c2a" "#383835" <<<"$DATA" >"$OUT/gpu-sweep-dark.svg"

echo "wrote $OUT/gpu-sweep-light.svg and $OUT/gpu-sweep-dark.svg"
