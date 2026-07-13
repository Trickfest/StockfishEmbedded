#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"
Scripts/download-nnue.sh

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
