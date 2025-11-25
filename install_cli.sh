#!/bin/bash
set -e

USE_ZENZAI=0
USE_ZENZAI_CPU=0
USE_ZENZAI_COREML=0
USE_DEBUG=0

fail() {
  echo "❌ $*" >&2
  exit 1
}

version_ge() {
  # success if $1 >= $2
  [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

# Parse args
for arg in "$@"; do
  case "$arg" in
    --zenzai) USE_ZENZAI=1 ;;
    --zenzai-cpu) USE_ZENZAI_CPU=1 ;;
    --zenzai-coreml) USE_ZENZAI_COREML=1 ;;
    --debug)
      echo "⚠️ Debug mode is enabled. This may cause performance issues."
      USE_DEBUG=1
      ;;
    *)
      ;;
  esac
done

CONFIGURATION="release"
[ "$USE_DEBUG" -eq 1 ] && CONFIGURATION="debug"

if [ "$USE_ZENZAI_COREML" -eq 1 ]; then
  OS_VERSION=$(sw_vers -productVersion)
  SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo "0")
  MIN_OS_FOR_COREML="15.5"
  MIN_SDK_FOR_COREML="15.5"

  version_ge "$OS_VERSION" "$MIN_OS_FOR_COREML" || fail "Zenzai CoreML requires macOS >= $MIN_OS_FOR_COREML (found $OS_VERSION). Use --zenzai / --zenzai-cpu or upgrade macOS/Xcode."
  version_ge "$SDK_VERSION" "$MIN_SDK_FOR_COREML" || fail "Zenzai CoreML requires macOS SDK >= $MIN_SDK_FOR_COREML (found $SDK_VERSION). Install Xcode with that SDK or use --zenzai / --zenzai-cpu."

  export MACOSX_DEPLOYMENT_TARGET="$MIN_OS_FOR_COREML"
  ARCH=$(uname -m)
  if [ "$ARCH" = "arm64" ]; then
    TARGET_TRIPLE="arm64-apple-macos$MIN_OS_FOR_COREML"
  else
    TARGET_TRIPLE="x86_64-apple-macosx$MIN_OS_FOR_COREML"
  fi
  SWIFT_BUILD_EXTRA_ARGS=("-Xswiftc" "-target" "-Xswiftc" "$TARGET_TRIPLE")
  echo "📦 Building with Zenzai CoreML support (MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET)..."
  swift build -c "$CONFIGURATION" -Xcxx -xobjective-c++ --traits ZenzaiCoreML "${SWIFT_BUILD_EXTRA_ARGS[@]}"
elif [ "$USE_ZENZAI" -eq 1 ]; then
  echo "📦 Building with Zenzai support..."
  swift build -c "$CONFIGURATION" -Xcxx -xobjective-c++ --traits Zenzai
elif [ "$USE_ZENZAI_CPU" -eq 1 ]; then
  echo "📦 Building with ZenzaiCPU (CPU-only) support..."
  swift build -c "$CONFIGURATION" -Xcxx -xobjective-c++ --traits ZenzaiCPU
else
  echo "📦 Building..."
  swift build -c "$CONFIGURATION" -Xcxx -xobjective-c++
fi

# Copy Required Resources
sudo cp -R ".build/${CONFIGURATION}/llama.framework" /usr/local/lib/
if [ "$USE_ZENZAI_COREML" -eq 1 ]; then
  COREML_FW_PATH=$(find ".build" -type d -path "*/${CONFIGURATION}/ZenzCoreMLStateful8bit.framework" -print -quit)
  if [ -z "$COREML_FW_PATH" ]; then
    COREML_FW_PATH=$(find ".build" -type d -name "ZenzCoreMLStateful8bit.framework" -print -quit)
  fi
  [ -n "$COREML_FW_PATH" ] || fail "ZenzCoreMLStateful8bit.framework not found in .build. Build with --zenzai-coreml first."
  echo "📦 Installing ZenzCoreMLStateful8bit.framework from $COREML_FW_PATH"
  sudo cp -R "$COREML_FW_PATH" /usr/local/lib/
fi

# Copy resource bundles needed at runtime (SwiftPM puts them next to the binary)
BUNDLE_NAME="AzooKeyKanaKanjiConverter_KanaKanjiConverterModuleWithDefaultDictionary.bundle"
BUNDLE_PATH=$(find ".build" -type d -path "*/${CONFIGURATION}/${BUNDLE_NAME}" -print -quit)
if [ -z "$BUNDLE_PATH" ]; then
  BUNDLE_PATH=$(find ".build" -type d -name "${BUNDLE_NAME}" -print -quit)
fi
[ -n "$BUNDLE_PATH" ] || fail "${BUNDLE_NAME} not found in .build. Build first, then run install_cli.sh."
echo "📦 Installing resource bundle from $BUNDLE_PATH"
sudo cp -R "$BUNDLE_PATH" /usr/local/bin/

# add rpath
RPATH="/usr/local/lib/"
BINARY_PATH=".build/${CONFIGURATION}/CliTool"

if ! otool -l "$BINARY_PATH" | grep -q "$RPATH"; then
    install_name_tool -add_rpath "$RPATH" "$BINARY_PATH"
else
    echo "✅ RPATH $RPATH is already present in $BINARY_PATH"
fi

# if debug mode, codesign is required to execute
if [ "$USE_DEBUG" -eq 1 ]; then
  echo "🔒 Signing the binary for debug mode..."
  codesign --force --sign - "$BINARY_PATH"
fi

# Install
sudo cp -f "$BINARY_PATH" /usr/local/bin/anco
