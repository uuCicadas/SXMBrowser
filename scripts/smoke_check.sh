#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
WORKSPACE_DIR="${ROOT_DIR:h}"
SAMPLE_DIR="${1:-$WORKSPACE_DIR/example-graph}"

export DOTNET_CLI_HOME="${DOTNET_CLI_HOME:-/tmp/dotnet-home}"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export MSBUILDDISABLENODEREUSE=1

dotnet build "$ROOT_DIR/tools/SXMBrowser.Smoke/SXMBrowser.Smoke.csproj" \
  -c Release \
  --no-restore \
  -m:1

dotnet "$ROOT_DIR/tools/SXMBrowser.Smoke/bin/Release/net10.0/SXMBrowserSmoke.dll" \
  --canonical-sample "$SAMPLE_DIR"
