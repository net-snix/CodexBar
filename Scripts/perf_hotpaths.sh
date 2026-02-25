#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_FILE="${CODEXBAR_PERF_LOG:-/tmp/codexbar-perf.log}"

cd "$ROOT_DIR"

export CODEXBAR_PROFILE_PERF=1

echo "Running hot-path perf diagnostics with CODEXBAR_PROFILE_PERF=1"
echo "Log file: $LOG_FILE"

swift test --filter "(UsageStoreCoverageTests|BatteryDrainDiagnosticTests)" 2>&1 | tee "$LOG_FILE"

echo
echo "Perf events:"
grep -n "com.steipete.codexbar.performance" "$LOG_FILE" || true
