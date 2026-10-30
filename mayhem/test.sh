#!/usr/bin/env bash
#
# mayhem/test.sh — RUNS upstream's own ctest suite (built by mayhem/build.sh into build/), then layers
# known-answer assertions on the files the suite produced. ctest only judges each test binary's exit
# code, so on its own it cannot tell a working library from a program that exits 0 immediately; the
# KATs below read the generated artifacts from bash, where a neutered program cannot hide.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
SRC="${SRC:-/mayhem}"
cd "$SRC"

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

[ -x build/PDFWriterTesting/PDFWriterTesting ] || { echo "build/PDFWriterTesting/PDFWriterTesting missing: mayhem/build.sh must build it" >&2; emit_ctrf cmake-ctest 0 1; exit 1; }

# Fresh output dir so artifacts left by an earlier run can't satisfy the assertions below.
OUT=build/Testing/Output
rm -rf "$OUT"; mkdir -p "$OUT"

ctest_log="$(mktemp)"
(cd build && ctest -j"$MAYHEM_JOBS" --output-on-failure) 2>&1 | tee "$ctest_log"
total="$(sed -n 's/.*tests passed, \([0-9]*\) tests failed out of \([0-9]*\).*/\2/p' "$ctest_log" | tail -1)"
failed="$(sed -n 's/.*tests passed, \([0-9]*\) tests failed out of \([0-9]*\).*/\1/p' "$ctest_log" | tail -1)"
rm -f "$ctest_log"
if [ -z "$total" ] || [ -z "$failed" ] || [ "$total" -lt 100 ]; then
  echo "ctest ran fewer tests than the suite has (total='${total:-}'); treating as failure" >&2
  emit_ctrf cmake-ctest 0 1; exit 1
fi
passed=$(( total - failed ))

# --- known-answer assertions on the suite's generated artifacts -----------------------------------
kat() {  # kat <description> <command...>
  if "${@:2}" >/dev/null 2>&1; then passed=$(( passed + 1 )); echo "KAT ok:   $1"
  else failed=$(( failed + 1 )); echo "KAT FAIL: $1" >&2; fi
}
has()   { grep -aqF -- "$2" "$1"; }           # has <file> <literal>
count() { [ "$(grep -ac -- "$2" "$1")" -eq "$3" ]; }  # count <file> <regex> <exact n>

kat "BufferedOutputStreamTest wrote exactly 'abcde'" test "$(cat "$OUT/BufferedOutputStreamTest.txt")" = "abcde"
kat "SimpleContent.pdf is a PDF 1.3 file"                  has "$OUT/SimpleContent.pdf" "%PDF-1.3"
kat "SimpleContent.pdf has an A4 MediaBox"                 has "$OUT/SimpleContent.pdf" "/MediaBox [ 0 0 595 842 ]"
kat "SimpleContent.pdf has one page"                       has "$OUT/SimpleContent.pdf" "/Count 1"
kat "SimpleContent.pdf trailer /Size is 8"                 has "$OUT/SimpleContent.pdf" "/Size 8"
kat "EmptyPages.pdf has four pages"                        has "$OUT/EmptyPages.pdf" "/Count 4"
kat "EmptyPages.pdf has four MediaBoxes"                   count "$OUT/EmptyPages.pdf" "/MediaBox \[ 0 0 595 842 \]" 4
kat "PDFObjectParserTest parsed '(val%ami)'"               has "$OUT/PDFObjectParserTest.txt" "Parse passed: '(val%ami)'"
kat "PDFObjectParserTest has 17 passing parses"            count "$OUT/PDFObjectParserTest.txt" "^Parse passed" 17
kat "PDFObjectParserTest has no failing parse"             count "$OUT/PDFObjectParserTest.txt" "Parse failed" 0
kat "PDFParserTest walked a stream object"                 has "$OUT/PDFParserTestOutput.txt" "Stream . iterating stream dictionary:"

emit_ctrf cmake-ctest "$passed" "$failed"
