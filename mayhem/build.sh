#!/usr/bin/env bash
#
# xbps/mayhem/build.sh — build void-linux/xbps' proplib (portableproplib) plist parser as a
# sanitized libFuzzer target (+ a standalone reproducer).
#
# Fuzzed surface: xbps_dictionary_internalize() — the in-memory XML property-list parser that turns
# untrusted package/repository metadata bytes into a proplib object graph (see
# mayhem/harnesses/xbps_plist_fuzzer.c). We build xbps' OWN library via its ./configure + make so the
# real parser objects are produced, then compile libxbps.a under $SANITIZER_FLAGS so the PARSER code
# (not just the harness) is instrumented.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/OUT/
# STANDALONE_FUZZ_MAIN). xbps depends on libarchive (pkg-config), openssl (libcrypto) and zlib.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${OUT:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE STANDALONE_FUZZ_MAIN OUT MAYHEM_JOBS

cd "$SRC"

HARNESS_DIR="$SRC/mayhem/harnesses"

# ── 1) Configure + build xbps' own libxbps.a, compiled with $SANITIZER_FLAGS ───────────────────────
# Pass the sanitizer flags via CFLAGS so every library object (incl. the proplib parser) is
# instrumented. -fsanitize=fuzzer-no-link lets the parser collect coverage feedback while the
# fuzzing-engine main is linked in only at the final harness link step.
# Build coverage instrumentation only for the parser TUs (not the whole lib) is unnecessary here:
# instrumenting all of libxbps is fine and gives the fuzzer a complete picture of the parse path.
INCS="-I$SRC/include -I$SRC/include/xbps -I$SRC/lib/portableproplib -I$SRC/lib/portableproplib/prop"
LIBXBPS="$SRC/lib/libxbps.a"

# xbps' configure writes config.mk and (via `make`) generates include/xbps.h from xbps.h.in.
./configure --prefix=/usr
make -j"$MAYHEM_JOBS" -C include      # generate include/xbps.h

# NOTE: xbps' config.mk does `CFLAGS = -O2` (HARD `=`, not `+=`), so an exported CFLAGS env var is
# clobbered. We therefore pass CFLAGS as a `make` COMMAND-LINE variable, which overrides the whole
# Makefile assignment (make precedence: command line > makefile). We also drop -Werror that config.mk
# would otherwise append (the sanitized/coverage build trips extra warnings).
CLEAN_CFLAGS="-O1 $DEBUG_FLAGS"
# Sanitized build: instrument the parser AND collect coverage feedback (-fsanitize=fuzzer-no-link).
SAN_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -O1"

# ── 1a) CLEAN (non-sanitized) libxbps.a, set aside for mayhem/test.sh's honest oracle ──────────────
# Built first with normal flags so the golden oracle links without an ASan/UBSan runtime — keeping
# test.sh independent of the sanitized fuzz build.
make -j"$MAYHEM_JOBS" -C lib libxbps.a CFLAGS="$CLEAN_CFLAGS"
[ -f "$LIBXBPS" ] || { echo "ERROR: clean libxbps.a not built" >&2; exit 1; }
mkdir -p "$SRC/mayhem-build"
cp "$LIBXBPS" "$SRC/mayhem-build/libxbps-clean.a"   # outside lib/ — `make clean` globs libxbps*
make -C lib clean >/dev/null 2>&1 || true

# ── 1b) SANITIZED libxbps.a for the fuzzer (the parser is instrumented + coverage-fed) ─────────────
make -j"$MAYHEM_JOBS" -C lib libxbps.a CFLAGS="$SAN_CFLAGS"
[ -f "$LIBXBPS" ] || { echo "ERROR: sanitized libxbps.a not built" >&2; exit 1; }

# Link deps of libxbps (proplib needs zlib; libxbps full API pulls in libarchive + libcrypto).
DEPS="$(pkg-config --libs libarchive) -lcrypto -lz -lpthread"

# ── 2) Build the harness twice: libFuzzer target (-> $OUT) + standalone reproducer ────────────────
HARNESS=xbps_plist_fuzzer

# libFuzzer target
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $INCS \
    "$HARNESS_DIR/$HARNESS.c" $LIB_FUZZING_ENGINE "$LIBXBPS" $DEPS \
    -o "$OUT/$HARNESS"

# standalone reproducer (no libFuzzer runtime; reads one input file)
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $INCS \
    "$HARNESS_DIR/$HARNESS.c" "$STANDALONE_FUZZ_MAIN" "$LIBXBPS" $DEPS \
    -o "$OUT/$HARNESS-standalone"

echo "built $HARNESS (+ standalone)"
ls -la "$OUT/$HARNESS" "$OUT/$HARNESS-standalone"
echo "build.sh complete"
