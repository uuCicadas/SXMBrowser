#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"

export DOTNET_CLI_HOME="${DOTNET_CLI_HOME:-/tmp/dotnet-home}"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export MSBUILDDISABLENODEREUSE=1

dotnet build "$ROOT_DIR/tools/SXMBrowser.Benchmark/SXMBrowser.Benchmark.csproj" \
  -c Release \
  --no-restore \
  -m:1

dotnet "$ROOT_DIR/tools/SXMBrowser.Benchmark/bin/Release/net10.0/SXMBrowserBenchmark.dll" \
  --files "${BENCH_FILES:-500}" \
  --width "${BENCH_WIDTH:-512}" \
  --height "${BENCH_HEIGHT:-512}" \
  --trials "${BENCH_TRIALS:-5}" \
  --max-scan-ms "${BENCH_MAX_SCAN_MS:-1000}" \
  --max-image-ms "${BENCH_MAX_IMAGE_MS:-100}" \
  --max-thumbnail-ms "${BENCH_MAX_THUMBNAIL_MS:-100}"
