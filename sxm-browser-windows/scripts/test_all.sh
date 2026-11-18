#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"

export DOTNET_CLI_HOME="${DOTNET_CLI_HOME:-/tmp/dotnet-home}"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export MSBUILDDISABLENODEREUSE=1

dotnet test "$ROOT_DIR/tests/SXMBrowser.Tests/SXMBrowser.Tests.csproj" \
  -c Release \
  --no-restore \
  -m:1 \
  -p:UseSharedCompilation=false \
  --verbosity minimal
