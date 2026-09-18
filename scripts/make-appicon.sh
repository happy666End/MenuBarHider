#!/bin/bash
# Builds MenuBarHider/Resources/Assets.xcassets/AppIcon.appiconset from assets/icon.png (1024x1024).
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=assets/icon.png
OUT=MenuBarHider/Resources/Assets.xcassets/AppIcon.appiconset
mkdir -p "$OUT"
entries=()
for spec in 16:1 16:2 32:1 32:2 128:1 128:2 256:1 256:2 512:1 512:2; do
  size=${spec%%:*}; scale=${spec##*:}; px=$((size * scale))
  file="icon_${size}x${size}@${scale}x.png"
  sips -z "$px" "$px" "$SRC" --out "$OUT/$file" >/dev/null
  entries+=("{\"filename\":\"$file\",\"idiom\":\"mac\",\"scale\":\"${scale}x\",\"size\":\"${size}x${size}\"}")
done
printf '{"images":[%s],"info":{"author":"xcode","version":1}}\n' "$(IFS=,; echo "${entries[*]}")" \
  | python3 -m json.tool > "$OUT/Contents.json"
cat > MenuBarHider/Resources/Assets.xcassets/Contents.json <<'JSON'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
echo "AppIcon written to $OUT"
