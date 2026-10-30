#!/usr/bin/env bash
#
# mayhem/build.sh — builds (1) the sanitized + libFuzzer-instrumented PDFWriter library and the
# upstream in-tree fuzz harnesses (PDFWriterTesting/*FuzzingHarness.cpp), each as a libFuzzer
# binary and a `-standalone` reproducer, and (2) the project's own test suite with NORMAL flags.
# Idempotent and air-gapped: everything is bundled in-tree or comes from apt packages in the base.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

SRC="${SRC:-/mayhem}"
cd "$SRC"

# --- 1) sanitized, coverage-instrumented library (build-sanitizer/ is gitignored upstream) -----
FUZZ_BUILD="$SRC/build-sanitizer"
# DEBUG_FLAGS goes last so -gdwarf-3 wins over any -g carried by the sanitizer flags.
LIB_FLAGS="-O2 $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
cmake -S . -B "$FUZZ_BUILD" -G Ninja \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$LIB_FLAGS" -DCMAKE_CXX_FLAGS="$LIB_FLAGS" \
  -DCMAKE_BUILD_TYPE= -DUSE_BUNDLED=TRUE
cmake --build "$FUZZ_BUILD" -j"$MAYHEM_JOBS" --target PDFWriter

# Static archives of the library and every bundled dependency, plus system OpenSSL.
mapfile -t ARCHIVES < <(find "$FUZZ_BUILD" -name '*.a' | sort)
[ "${#ARCHIVES[@]}" -gt 0 ] || { echo "no static archives found in $FUZZ_BUILD" >&2; exit 1; }
LIBS=(-Wl,--start-group "${ARCHIVES[@]}" -Wl,--end-group -lssl -lcrypto -lpthread)

# --- 2) harnesses: libFuzzer binary + standalone reproducer, leak detection off ----------------
HFLAGS="-O2 $SANITIZER_FLAGS $DEBUG_FLAGS -DUSE_OPENSSL_AES=1"
INCLUDES=(-I"$SRC/PDFWriter" -I"$SRC/PDFWriterTesting")

$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o /tmp/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -x c -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o

# target name:harness source
HARNESSES=(
  pdf_parser:PDFParserFuzzingHarness
  jpeg_image_parser:JPEGImageParserFuzzingHarness
  flate_decode_stream:InputFlateDecodeStreamFuzzingHarness
  lzw_decode_stream:InputLZWDecodeStreamFuzzingHarness
  aes_decode_stream:InputAESDecodeStreamFuzzingHarness
  opentype_file_input:OpenTypeFileInputFuzzingHarness
  cff_file_input:CFFFileInputFuzzingHarness
  tiff_image_handler:TIFFImageHandlerFuzzingHarness
)
for entry in "${HARNESSES[@]}"; do
  name="${entry%%:*}" ; srcname="${entry##*:}"
  $CXX $HFLAGS "${INCLUDES[@]}" -c "PDFWriterTesting/$srcname.cpp" -o "/tmp/$name.o"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "/tmp/$name.o" /tmp/lsan_off.o "${LIBS[@]}" -o "$SRC/$name"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "/tmp/$name.o" /tmp/standalone_main.o /tmp/lsan_off.o "${LIBS[@]}" -o "$SRC/$name-standalone"
done

# --- 3) the project's own test suite, NORMAL flags (build/ is gitignored upstream) --------------
cmake -S . -B build -G Ninja \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build build -j"$MAYHEM_JOBS" --target PDFWriterTesting
