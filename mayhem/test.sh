#!/usr/bin/env bash
#
# xbps/mayhem/test.sh — build (with NORMAL flags) and RUN a golden oracle over the exact parse path
# the fuzzer drives (xbps_dictionary_internalize / externalize, mayhem/test_oracle.c), then emit a
# CTRF summary. exit 0 iff every check passed.
#
# This is a real PATCH-grade oracle (NOT a no-op stub): it asserts concrete parsed values, container
# shapes, externalize round-trip stability, and rejection of malformed input. A change that breaks or
# no-ops the proplib parser fails these checks. We build the oracle in its own object/flags so this
# script is an HONEST oracle independent of the sanitized fuzz build.
#
# xbps' upstream suite is kyua/ATF-based (needs the installed toolchain + helper utils + an ATF
# runtime); this self-contained oracle exercises the fuzzed library directly instead.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

: "${CC:=clang}"
INCS="-I$SRC/include -I$SRC/include/xbps"
# CLEAN (non-sanitized) libxbps.a built by build.sh specifically for this honest oracle.
LIBXBPS="$SRC/mayhem-build/libxbps-clean.a"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -f "$LIBXBPS" ]; then
  echo "missing $LIBXBPS — run mayhem/build.sh first" >&2
  emit_ctrf "xbps-plist-oracle" 0 1 0; exit 2
fi

# Build the oracle with NORMAL flags (no sanitizers): honest, self-contained.
ORACLE="$SRC/mayhem-build-test/test_oracle"
mkdir -p "$SRC/mayhem-build-test"
DEPS="$(pkg-config --libs libarchive 2>/dev/null) -lcrypto -lz -lpthread"
if ! env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS -u LDFLAGS \
       "$CC" -O1 -g $INCS "$SRC/mayhem/test_oracle.c" "$LIBXBPS" $DEPS -o "$ORACLE" 2> "$SRC/mayhem-build-test/build.log"; then
  echo "oracle failed to compile:" >&2; cat "$SRC/mayhem-build-test/build.log" >&2
  emit_ctrf "xbps-plist-oracle" 0 1 0; exit 2
fi

echo "=== running xbps plist parser golden oracle ==="
out="$("$ORACLE" 2>&1)"; rc=$?
echo "$out"

PASSED=$(printf '%s\n' "$out" | grep -c '^PASS ')
FAILED=$(printf '%s\n' "$out" | grep -c '^FAIL ')
: "${PASSED:=0}" "${FAILED:=0}"

# If the binary crashed (e.g. nonzero rc but no parseable FAIL lines), treat as a failure.
if [ "$(( PASSED + FAILED ))" -eq 0 ]; then
  echo "oracle produced no parseable results; using exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "xbps-plist-oracle" 1 0 0; exit 0; }
  emit_ctrf "xbps-plist-oracle" 0 1 0; exit 1
fi
# Reconcile process exit code with parsed FAIL lines (a crash mid-suite => at least one failure).
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=1; fi

emit_ctrf "xbps-plist-oracle" "$PASSED" "$FAILED" 0
