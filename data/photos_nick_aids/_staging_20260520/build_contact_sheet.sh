#!/bin/bash
# Build a scrollable contact sheet of the staged photos, ordered by capture time,
# with visual separators where the capture-time gap suggests a device switch.
set -euo pipefail
cd "$(dirname "$0")"

THUMBS=thumbs
mkdir -p "$THUMBS"

echo "Converting HEIC -> JPG thumbnails..."
n=0
for f in IMG_*.HEIC; do
  out="$THUMBS/${f%.HEIC}.jpg"
  if [ ! -s "$out" ]; then
    sips -s format jpeg -Z 420 "$f" --out "$out" >/dev/null 2>&1 || echo "  FAIL $f"
  fi
  n=$((n+1))
  [ $((n % 25)) -eq 0 ] && echo "  ...$n converted"
done
echo "Converted $n thumbnails."

# Emit "epoch<TAB>name" sorted by capture time (file mtime preserved from phone).
LIST=$(stat -f "%m	%N" IMG_*.HEIC | sort -n)

HTML=contact_sheet.html
{
  cat <<'HEAD'
<!doctype html><html><head><meta charset="utf-8">
<title>Recycled Sound — photo sort 2026-05-20</title>
<style>
  body{font-family:-apple-system,system-ui,sans-serif;background:#111;color:#eee;margin:0;padding:16px}
  h1{font-size:18px} .hint{color:#9ad;font-size:13px;margin-bottom:16px}
  .grid{display:flex;flex-wrap:wrap;gap:8px}
  .cell{width:200px;background:#1c1c1c;border-radius:8px;padding:6px;text-align:center}
  .cell img{width:188px;height:auto;border-radius:4px;display:block}
  .cap{font-size:12px;margin-top:4px} .num{font-weight:700;color:#fff} .time{color:#888}
  .sep{flex-basis:100%;height:0;border-top:2px dashed #e55;margin:14px 0 6px;position:relative}
  .sep span{position:absolute;top:-10px;left:0;background:#111;color:#e55;font-size:12px;padding:0 8px}
</style></head><body>
<h1>Photo sort — 2026-05-20 (190 photos, capture-time order)</h1>
<p class="hint">Red dashed lines mark capture-time gaps &gt; 90s (likely device switches). Read off the IMG number ranges per device and tell Claude, e.g. "B07 Signia = 1403–1422".</p>
<div class="grid">
HEAD

  prev=""
  while IFS=$'\t' read -r epoch name; do
    base="${name%.HEIC}"
    num="${base#IMG_}"
    hhmm=$(date -r "$epoch" "+%a %H:%M:%S")
    if [ -n "$prev" ]; then
      gap=$((epoch - prev))
      if [ "$gap" -gt 90 ]; then
        printf '<div class="sep"><span>gap %dm %ds</span></div>\n' $((gap/60)) $((gap%60))
      fi
    fi
    printf '<div class="cell"><img loading="lazy" src="%s/%s.jpg"><div class="cap"><span class="num">%s</span><br><span class="time">%s</span></div></div>\n' "$THUMBS" "$base" "$num" "$hhmm"
    prev="$epoch"
  done <<< "$LIST"

  echo '</div></body></html>'
} > "$HTML"

echo "WROTE $(pwd)/$HTML"
