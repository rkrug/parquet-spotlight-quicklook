#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect_success() {
  local label="$1"
  shift
  if ! "$@" >/tmp/parquet_script_test.out 2>/tmp/parquet_script_test.err; then
    echo "---- stdout ----" >&2
    cat /tmp/parquet_script_test.out >&2 || true
    echo "---- stderr ----" >&2
    cat /tmp/parquet_script_test.err >&2 || true
    fail "$label"
  fi
}

expect_failure() {
  local label="$1"
  shift
  set +e
  "$@" >/tmp/parquet_script_test.out 2>/tmp/parquet_script_test.err
  local rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    echo "---- stdout ----" >&2
    cat /tmp/parquet_script_test.out >&2 || true
    echo "---- stderr ----" >&2
    cat /tmp/parquet_script_test.err >&2 || true
    fail "$label (expected failure, got success)"
  fi
}

echo "==> [1/6] Build script smoke test"
expect_success "scripts/build.sh should succeed" ./scripts/build.sh
[[ -d "$ROOT_DIR/build/Parquet.mdimporter" ]] || fail "Parquet.mdimporter missing after build"
[[ -d "$ROOT_DIR/build/Parquet Quick Look and Index.app" ]] || fail "Parquet Quick Look and Index.app missing after build"

echo "==> [2/6] Uninstall dry-run smoke test"
expect_success "scripts/uninstall.sh --dry-run should succeed" ./scripts/uninstall.sh --dry-run
if ! rg -Fq "Dry run enabled" /tmp/parquet_script_test.out; then
  fail "uninstall dry-run output missing expected marker"
fi

echo "==> [3/6] Release script help smoke test"
expect_success "scripts/release.sh --help should succeed" ./scripts/release.sh --help
if ! rg -Fq "Usage: ./scripts/release.sh" /tmp/parquet_script_test.out; then
  fail "release help output missing usage text"
fi

echo "==> [4/6] Release script invalid tag guard"
expect_failure "scripts/release.sh should reject invalid tags" ./scripts/release.sh invalid-tag
if ! rg -Fq "error: tag must look like" /tmp/parquet_script_test.err; then
  fail "invalid-tag check missing expected error text"
fi

echo "==> [5/6] Release script notes-file guard"
expect_failure "scripts/release.sh should fail when --notes file is missing" ./scripts/release.sh v0.4.0 --notes /tmp/does-not-exist-notes.md
if ! rg -Fq "error: notes file does not exist" /tmp/parquet_script_test.err; then
  fail "missing-notes check missing expected error text"
fi

echo "==> [6/6] Core logic test harness"
expect_success "scripts/test_core.sh should succeed" ./scripts/test_core.sh
if ! rg -Fq "PASS: core logic tests completed" /tmp/parquet_script_test.out; then
  fail "core test harness did not report success"
fi

echo "PASS: script smoke tests completed"
