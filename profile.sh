#!/usr/bin/env bash
set -euo pipefail

SKIP_TESTING=false
GPU_METRICS=true
AUTO_OPEN=false
CPU_MODE=false
NGRAM_TRAIN_TEST=false
NGRAM_TRAIN_FILE_TEST=false
# Predeclare as empty array to avoid -u errors on expansion
GPU_INSTR=()
TEST_ENV=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-testing)
      SKIP_TESTING=true
      ;;
    --no-gpu-metrics)
      GPU_METRICS=false
      ;;
    --auto-open)
      AUTO_OPEN=true
      ;;
    --cpu)
      CPU_MODE=true
      ;;
    --ngram-train-test)
      NGRAM_TRAIN_TEST=true
      ;;
    --ngram-train-file-test)
      NGRAM_TRAIN_FILE_TEST=true
      ;;
    *)
      echo "[error] unknown option: $1" 1>&2
      exit 1
      ;;
  esac
  shift
done

# Switch to CPU-only trait and metrics if requested
if [[ "$CPU_MODE" == true ]]; then
  GPU_METRICS=false
fi

if [[ "$NGRAM_TRAIN_TEST" == true ]]; then
  GPU_METRICS=false
fi
if [[ "$NGRAM_TRAIN_FILE_TEST" == true ]]; then
  GPU_METRICS=false
fi

if [[ "$NGRAM_TRAIN_TEST" == true && "$NGRAM_TRAIN_FILE_TEST" == true ]]; then
  echo "[error] --ngram-train-test and --ngram-train-file-test are mutually exclusive" 1>&2
  exit 1
fi

echo "[info] options: skip-testing=$SKIP_TESTING, gpu-metrics=$GPU_METRICS, auto-open=$AUTO_OPEN, cpu-mode=$CPU_MODE, ngram-train-test=$NGRAM_TRAIN_TEST, ngram-train-file-test=$NGRAM_TRAIN_FILE_TEST"

if [[ "$GPU_METRICS" == true ]]; then
  GPU_INSTR=(--instrument 'Metal Application')
else
  GPU_INSTR=()
  echo "[info] GPU metrics disabled"
fi

# 設定
TEST_IDS=(
  "KanaKanjiConverterModuleWithDefaultDictionaryTests.ZenzaiTests/testRequestCandidates_AfterGradual_Roman2Kana_NoIncrementalTypo"
  "KanaKanjiConverterModuleWithDefaultDictionaryTests.ZenzaiTests/testTypoCorrection_AfterGradualRequestCandidates_Roman2Kana"
)
# CPUモードでも同じ2ケースを実行
if [[ "$CPU_MODE" == true ]]; then
  TEST_IDS=(
    "KanaKanjiConverterModuleWithDefaultDictionaryTests.ZenzaiTests/testTypoCorrection_OneShot_Roman2Kana"
    "KanaKanjiConverterModuleWithDefaultDictionaryTests.ZenzaiTests/testTypoCorrection_AfterGradualRequestCandidates_Roman2Kana"
  )
fi
TRAIT="Zenzai"
if [[ "$CPU_MODE" == true ]]; then
  TRAIT="ZenzaiCPU"
fi
if [[ "$NGRAM_TRAIN_TEST" == true ]]; then
  TEST_IDS=(
    "EfficientNGramTests.SwiftNGramTests/testTrainProfileRandomAonCorpus"
  )
  TRAIT="Zenzai"
  TEST_ENV=("ENABLE_NGRAM_PROFILE_TEST=1")
fi
if [[ "$NGRAM_TRAIN_FILE_TEST" == true ]]; then
  TEST_IDS=(
    "EfficientNGramTests.SwiftNGramTests/testTrainProfileRandomAonCorpusFromFile"
  )
  TRAIT="Zenzai"
  TEST_ENV=("ENABLE_NGRAM_FILE_PROFILE_TEST=1")
fi

# /tmp 配下に作業ディレクトリ
WORKDIR="$(mktemp -d "/tmp/azookey_prof_XXXXXX")"
TRACE="$WORKDIR/ProfileRelease.trace"

echo "[info] workdir: $WORKDIR"

 # 0) SwiftPMでトレイト有効のままテストバンドルをビルド
"$(xcrun --find swift)" build -c release --build-tests --traits "$TRAIT" -Xswiftc -enable-testing
BUILD_BIN="$("$(xcrun --find swift)" build -c release --show-bin-path)"
echo "[info] bin: $BUILD_BIN"

# SwiftPMのテストバンドル（*.xctest）を特定
TEST_BUNDLE="$(/usr/bin/env ls -1d "$BUILD_BIN"/*.xctest | head -n1)"
if [[ -z "${TEST_BUNDLE:-}" || ! -d "$TEST_BUNDLE" ]]; then
  echo "[error] test bundle (.xctest) not found under $BUILD_BIN" 1>&2
  exit 1
fi
echo "[info] test bundle: $TEST_BUNDLE"

#"REL" を .build の release に指しておく
REL="$BUILD_BIN"

# DYLD_* に SwiftPM の出力ディレクトリと PackageFrameworks を先頭追加
PKGFW="$REL/PackageFrameworks"

export DYLD_FRAMEWORK_PATH="$REL${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}"
export DYLD_LIBRARY_PATH="$REL${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
[[ -d "$PKGFW" ]] && export DYLD_FRAMEWORK_PATH="$PKGFW:$DYLD_FRAMEWORK_PATH"

if [[ "$SKIP_TESTING" != true ]]; then
  # Precheck: run each test once to ensure it passes
  echo "[precheck] verifying tests pass before profiling…"
  for TEST_ID in "${TEST_IDS[@]}"; do
    echo "[precheck] running: $TEST_ID"
    if ! /usr/bin/env \
        ${TEST_ENV[@]+"${TEST_ENV[@]}"} \
        DYLD_FRAMEWORK_PATH="$DYLD_FRAMEWORK_PATH" \
        DYLD_LIBRARY_PATH="$DYLD_LIBRARY_PATH" \
        DYLD_FALLBACK_FRAMEWORK_PATH="$DYLD_FRAMEWORK_PATH" \
        "$(xcrun --find xctest)" \
        -XCTest "$TEST_ID" \
        "$TEST_BUNDLE" >/dev/null; then
      echo "[precheck][fail] $TEST_ID"
      exit 1
    else
      echo "[precheck][ok]   $TEST_ID"
    fi
  done
  echo "[precheck] all tests passed"
else
  echo "[precheck] skipped due to --skip-testing"
fi

# 3) Time Profiler で xctest を“直接”起動（トレイトはビルド済みなのでそのまま実行）
rm -rf "$TRACE"
echo "[save] trace: $TRACE"
for i in "${!TEST_IDS[@]}"; do
  TEST_ID="${TEST_IDS[$i]}"
  echo "[run] test: $TEST_ID"
  if [[ $i -eq 0 ]]; then
    xcrun xctrace record \
      --template 'Time Profiler' \
      ${GPU_INSTR[@]+"${GPU_INSTR[@]}"} \
      --output "$TRACE" \
      --launch -- \
      /usr/bin/env \
        ${TEST_ENV[@]+"${TEST_ENV[@]}"} \
        DYLD_FRAMEWORK_PATH="$DYLD_FRAMEWORK_PATH" \
        DYLD_LIBRARY_PATH="$DYLD_LIBRARY_PATH" \
        DYLD_FALLBACK_FRAMEWORK_PATH="$DYLD_FRAMEWORK_PATH" \
        "$(xcrun --find xctest)" \
        -XCTest "$TEST_ID" \
        "$TEST_BUNDLE"
  else
    xcrun xctrace record \
      --template 'Time Profiler' \
      ${GPU_INSTR[@]+"${GPU_INSTR[@]}"} \
      --output "$TRACE" \
      --append-run \
      --launch -- \
      /usr/bin/env \
        ${TEST_ENV[@]+"${TEST_ENV[@]}"} \
        DYLD_FRAMEWORK_PATH="$DYLD_FRAMEWORK_PATH" \
        DYLD_LIBRARY_PATH="$DYLD_LIBRARY_PATH" \
        DYLD_FALLBACK_FRAMEWORK_PATH="$DYLD_FRAMEWORK_PATH" \
        "$(xcrun --find xctest)" \
        -XCTest "$TEST_ID" \
        "$TEST_BUNDLE"
  fi
done

if [[ "$AUTO_OPEN" == true ]]; then
  echo "[open] $TRACE"
  open "$TRACE"
fi
