#!/usr/bin/env bash
# Phase 3 fuzz harnesses. Run from the repo root inside the dev shell:
#
#   verification/harness/fuzz.sh build            SDL (ASan+UBSan+coverage) in build-fuzz/, plus the targets
#   verification/harness/fuzz.sh seeds            regenerate the generated seed corpora
#   verification/harness/fuzz.sh run <t> [secs]   fuzz one target (default 300 s) with its corpus
#   verification/harness/fuzz.sh run-all [secs]   fuzz every target for [secs] each
#   verification/harness/fuzz.sh replay <t> <files…>   run inputs once (regressions, triage)
#
# Toolchain (see TRUSTED_BASE.md): on macOS 27 the nix clang ASan runtime hangs at startup and
# Apple clang ships no libFuzzer. So SDL and the targets are compiled by Apple clang with
# ASan+UBSan and libFuzzer's coverage instrumentation, and linked against the libFuzzer runtime
# archive from the nix clang (same LLVM major version, 21). On Linux the nix clang does all of it.
#
# Nothing here touches src/ or the upstream CMake files: SDL is configured with extra flags only.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
here="$root/verification/harness"
out="$root/build-fuzz"
targets=(fuzz_utf8 fuzz_iconv fuzz_rect fuzz_gamepad fuzz_bmp fuzz_wav)

# pointer-overflow stays recoverable so that ubsan.supp can silence it at one known site
# (F-017, readRlePixels); halt_on_error=1 still aborts on every unsuppressed report.
san="-fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=undefined -fsanitize-recover=pointer-overflow"
cov="-fsanitize-coverage=inline-8bit-counters,pc-table,trace-cmp"
if [ "$(uname -s)" = Darwin ]; then
  dev=$(env -u DEVELOPER_DIR xcode-select -p)
  apple() { env -u SDKROOT DEVELOPER_DIR="$dev" "$@"; }
  CC=/usr/bin/clang
  fuzzlib="$(clang -print-resource-dir)/lib/darwin/libclang_rt.fuzzer_osx.a"
  [ -e "$fuzzlib" ] || { echo "libFuzzer runtime not found at $fuzzlib (run inside the dev shell)" >&2; exit 2; }
  link=("$fuzzlib" -lc++)
  ccargs=(-DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_OBJC_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++)
else
  apple() { "$@"; }
  CC=clang
  link=(-fsanitize=fuzzer)
  ccargs=(-DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++)
fi

# Sanitizer options shared by every run. UBSan is non-recoverable (-fno-sanitize-recover), so any
# UB report aborts and libFuzzer saves the input. LeakSanitizer does not run on macOS.
export ASAN_OPTIONS="${ASAN_OPTIONS:-abort_on_error=1:detect_leaks=0:symbolize=1:allocator_may_return_null=1:max_allocation_size_mb=1024}"
supp=""
[ "${SDL_FUZZ_KNOWN:-}" = 1 ] || supp=":suppressions=$here/ubsan.supp"
export UBSAN_OPTIONS="${UBSAN_OPTIONS:-print_stacktrace=1:halt_on_error=1$supp}"

build_sdl() {
  mkdir -p "$out"
  apple cmake -S "$root" -B "$out" -G Ninja "${ccargs[@]}" -DCMAKE_BUILD_TYPE=Debug \
    -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_STATIC=OFF -DSDL_SHARED=ON \
    "-DCMAKE_C_FLAGS=$san $cov" "-DCMAKE_OBJC_FLAGS=$san $cov" \
    "-DCMAKE_SHARED_LINKER_FLAGS=-fsanitize=address,undefined" > "$out/configure.log" 2>&1 \
    || { tail -30 "$out/configure.log"; exit 1; }
  apple cmake --build "$out" > "$out/build.log" 2>&1 || { grep -E "error|FAILED" "$out/build.log" | head -30; exit 1; }
}

build() {
  [ -e "$out/build.ninja" ] && [ "${1:-}" != --reconfigure ] || build_sdl
  apple cmake --build "$out" > "$out/build.log" 2>&1 || { grep -E "error|FAILED" "$out/build.log" | head -30; exit 1; }
  mkdir -p "$out/fuzz"
  for t in "${targets[@]}" seedgen; do
    local extra=()
    [ "$t" = seedgen ] || extra=("${link[@]}")
    apple "$CC" -g -O1 $san $cov -I "$root/include" -I "$out/include-revision" "$here/$t.c" \
      -L "$out" -lSDL3 -Wl,-rpath,"$out" "${extra[@]}" -o "$out/fuzz/$t"
  done
  echo "built: ${targets[*]} (in $out/fuzz)"
}

seeds() {
  "$out/fuzz/seedgen" "$here/corpus"
  # Real assets from test/ (the WAV files are large, so only their first 4 KiB: the parser
  # reads the headers, and truncated data is itself an interesting case).
  head -c 4096 "$root/test/sample.wav" > "$here/corpus/fuzz_wav/sample_head.wav"
  head -c 4096 "$root/test/sword.wav" > "$here/corpus/fuzz_wav/sword_head.wav"
}

run() {
  local t=$1 secs=${2:-300}
  local corpus="$here/corpus/$t" work="$out/fuzz/work/$t"
  mkdir -p "$corpus" "$work" "$out/fuzz/crashes/$t"
  local dict=()
  [ -e "$here/dict/$t.dict" ] && dict=(-dict="$here/dict/$t.dict")
  # New corpus entries go to the work dir; the committed corpus is read-only input.
  # -max_len is part of the stated property ("for inputs of at most N bytes"), see README.md.
  "$out/fuzz/$t" "$work" "$corpus" "${dict[@]}" -max_total_time="$secs" -timeout=10 \
    -rss_limit_mb=4096 -max_len="$(maxlen "$t")" -print_final_stats=1 \
    -artifact_prefix="$out/fuzz/crashes/$t/" 2>&1 | tee "$out/fuzz/$t.log" \
    | grep -E "^#[0-9]+ +(INITED|DONE)|ERROR|SUMMARY|^stat::(number_of_executed_units|peak_rss|new_units_added)|Test unit written|^(F-|PROPERTY)" || true
}

maxlen() {
  case "$1" in
    fuzz_utf8|fuzz_iconv) echo 4096 ;;
    fuzz_rect) echo 1024 ;;
    fuzz_gamepad) echo 2048 ;;
    fuzz_bmp|fuzz_wav) echo 65536 ;;
  esac
}

case "${1:-}" in
  sdl) build_sdl ;;
  build) build "${2:-}" ;;
  seeds) seeds ;;
  run) run "$2" "${3:-300}" ;;
  run-all) for t in "${targets[@]}"; do echo "== $t"; run "$t" "${2:-300}"; done ;;
  replay) t=$2; shift 2; "$out/fuzz/$t" "$@" ;;
  *) sed -n '2,9p' "$0"; exit 2 ;;
esac
