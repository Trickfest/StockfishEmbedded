#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"
Scripts/download-nnue.sh

NNUE_FILE="$(sed -nE 's/^#define[[:space:]]+EvalFileDefaultName[[:space:]]+"([^"]+)".*/\1/p' \
  ThirdParty/Stockfish/src/evaluate.h | head -n 1)"
NNUE_PATH="Resources/NNUE/$NNUE_FILE"
for documentation_file in README.md AGENTS.md Resources/NNUE/README.md; do
  if ! grep -Fq "$NNUE_FILE" "$documentation_file"; then
    echo "$documentation_file does not name the current NNUE file: $NNUE_FILE" >&2
    exit 1
  fi
done

NNUE_SHA256="$(shasum -a 256 "$NNUE_PATH" | awk '{print $1}')"
for public_documentation_file in README.md Resources/NNUE/README.md; do
  if ! grep -Fq "$NNUE_SHA256" "$public_documentation_file"; then
    echo "$public_documentation_file does not contain the current NNUE SHA-256: $NNUE_SHA256" >&2
    exit 1
  fi
done

swift package dump-package >/dev/null
swift build
swift test

SIMULATOR_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
swift build \
  --triple arm64-apple-ios26.0-simulator \
  --sdk "$SIMULATOR_SDK"

CLEAN_PACKAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/stockfishembedded-clean-package.XXXXXX")"
cleanup() {
  rm -rf "$CLEAN_PACKAGE_ROOT"
}
trap cleanup EXIT

rsync -a \
  --exclude .build \
  --exclude .git \
  --exclude .swiftpm \
  --exclude build \
  --exclude 'Resources/NNUE/*.nnue' \
  "$REPO_ROOT/" "$CLEAN_PACKAGE_ROOT/"

(
  cd "$CLEAN_PACKAGE_ROOT"
  swift package dump-package >/dev/null
  swift build
  swift test
)

xcodebuild \
  -project StockfishEmbedded.xcodeproj \
  -scheme SFEngine-macOS \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build \
  build

xcodebuild \
  -project StockfishEmbedded.xcodeproj \
  -scheme SFEngineCLITestObjC \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build \
  build
./build/Build/Products/Debug/SFEngineCLITestObjC

xcodebuild \
  -project StockfishEmbedded.xcodeproj \
  -scheme SFEngineCLITestSwift \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build \
  build
./build/Build/Products/Debug/SFEngineCLITestSwift

xcodebuild \
  -project StockfishEmbedded.xcodeproj \
  -scheme SFEngineCLISoakTestSwift \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build \
  build
./build/Build/Products/Debug/SFEngineCLISoakTestSwift --iterations 5 --movetime 500

xcodebuild \
  -project StockfishEmbedded.xcodeproj \
  -scheme SFEngineTests \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build \
  test

xcodebuild \
  -project StockfishEmbedded.xcodeproj \
  -scheme SFEngineTestSwiftUI \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  build

echo "StockfishEmbedded validation succeeded"
