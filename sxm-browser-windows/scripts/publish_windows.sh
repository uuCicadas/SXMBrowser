#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
DIST_DIR="$ROOT_DIR/dist"
OUT_DIR="$DIST_DIR/SXMBrowser-win-x64"
ZIP_NAME="SXMBrowser-win-x64-v2.6.1.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"

export DOTNET_CLI_HOME="${DOTNET_CLI_HOME:-/tmp/dotnet-home}"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export MSBUILDDISABLENODEREUSE=1

ASSETS_FILE="$ROOT_DIR/src/SXMBrowser.Desktop/obj/project.assets.json"
if [[ ! -f "$ASSETS_FILE" ]] || ! grep -q "win-x64" "$ASSETS_FILE"; then
  dotnet restore "$ROOT_DIR/SXMBrowser.sln" \
    --source "$ROOT_DIR/.nuget/packages" \
    -m:1
fi

rm -rf "$OUT_DIR" "$ZIP_PATH"
mkdir -p "$OUT_DIR"

dotnet publish "$ROOT_DIR/src/SXMBrowser.Desktop/SXMBrowser.Desktop.csproj" \
  -c Release \
  -r win-x64 \
  --self-contained true \
  --no-restore \
  -p:PublishSingleFile=false \
  -p:DebugType=none \
  -p:DebugSymbols=false \
  -m:1 \
  -o "$OUT_DIR"

if command -v zip >/dev/null 2>&1; then
  (cd "$DIST_DIR" && zip -rq "$ZIP_NAME" "SXMBrowser-win-x64")
else
  python3 -c '
import os, sys, zipfile
dist_dir, out_dir, zip_path = sys.argv[1], sys.argv[2], sys.argv[3]
with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    for root, _, files in os.walk(out_dir):
        for name in sorted(files):
            full = os.path.join(root, name)
            rel = os.path.relpath(full, dist_dir)
            zf.write(full, rel)
' "$DIST_DIR" "$OUT_DIR" "$ZIP_PATH"
fi

echo "Published portable Windows directory: $OUT_DIR"
echo "Packaged Windows ZIP archive: $ZIP_PATH"
ls -lh "$OUT_DIR/SXMBrowser.exe" "$ZIP_PATH"
