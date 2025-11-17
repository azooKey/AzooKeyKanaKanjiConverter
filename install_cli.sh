#!/bin/bash
set -e

USE_ZENZAI=0
USE_ZENZAI_CPU=0
USE_ZENZAI_COREML=0
USE_DEBUG=0

# 引数の解析
for arg in "$@"; do
  if [ "$arg" = "--zenzai" ]; then
    USE_ZENZAI=1
  fi
  if [ "$arg" = "--zenzai-cpu" ]; then
    USE_ZENZAI_CPU=1
  fi
  if [ "$arg" = "--zenzai-coreml" ]; then
    USE_ZENZAI_COREML=1
  fi
  if [ "$arg" = "--debug" ]; then
    echo "⚠️ Debug mode is enabled. This may cause performance issues."
    USE_DEBUG=1
  fi
done

if [ "$USE_DEBUG" -eq 1 ]; then
  CONFIGURATION="debug"
else
  CONFIGURATION="release"
fi

if [ "$USE_ZENZAI_COREML" -eq 1 ]; then
  echo "📦 Building with Zenzai CoreML support..."
  swift build -c $CONFIGURATION -Xcxx -xobjective-c++ --traits ZenzaiCoreML
elif [ "$USE_ZENZAI" -eq 1 ]; then
  echo "📦 Building with Zenzai support..."
  swift build -c $CONFIGURATION -Xcxx -xobjective-c++ --traits Zenzai
elif [ "$USE_ZENZAI_CPU" -eq 1 ]; then
  echo "📦 Building with ZenzaiCPU (CPU-only) support..."
  swift build -c $CONFIGURATION -Xcxx -xobjective-c++ --traits ZenzaiCPU
else
  echo "📦 Building..."
  swift build -c $CONFIGURATION -Xcxx -xobjective-c++
fi

# Copy Required Resources
sudo cp -R .build/${CONFIGURATION}/llama.framework /usr/local/lib/
if [ "$USE_ZENZAI_COREML" -eq 1 ]; then
  COREML_FW_PATH=$(find ".build" -type d -path "*/${CONFIGURATION}/ZenzCoreMLStateful8bit.framework" -print -quit)
  if [ -z "$COREML_FW_PATH" ]; then
    COREML_FW_PATH=$(find ".build" -type d -name "ZenzCoreMLStateful8bit.framework" -print -quit)
  fi
  if [ -z "$COREML_FW_PATH" ]; then
    echo "❌ ZenzCoreMLStateful8bit.framework not found in .build. Please build with --zenzai-coreml first."
    exit 1
  fi
  echo "📦 Installing ZenzCoreMLStateful8bit.framework from $COREML_FW_PATH"
  sudo cp -R "$COREML_FW_PATH" /usr/local/lib/
fi

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
  codesign --force --sign - .build/${CONFIGURATION}/CliTool
fi

# Install
sudo cp -f .build/${CONFIGURATION}/CliTool /usr/local/bin/anco
