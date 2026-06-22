#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EVALUATE_HEADER="$REPO_ROOT/ThirdParty/Stockfish/src/evaluate.h"
NNUE_DIR="$REPO_ROOT/Resources/NNUE"

if [[ ! -f "$EVALUATE_HEADER" ]]; then
  echo "Could not find Stockfish evaluate.h at $EVALUATE_HEADER" >&2
  exit 1
fi

NNUE_FILE="$(sed -nE 's/^#define[[:space:]]+EvalFileDefaultName[[:space:]]+"([^"]+)".*/\1/p' "$EVALUATE_HEADER" | head -n 1)"

if [[ -z "$NNUE_FILE" ]]; then
  echo "Could not determine EvalFileDefaultName from $EVALUATE_HEADER" >&2
  exit 1
fi

case "$NNUE_FILE" in
  nn-*.nnue) ;;
  *)
    echo "Unexpected NNUE filename from EvalFileDefaultName: $NNUE_FILE" >&2
    exit 1
    ;;
esac

mkdir -p "$NNUE_DIR"

DESTINATION="$NNUE_DIR/$NNUE_FILE"
URL="https://tests.stockfishchess.org/api/nn/$NNUE_FILE"

if [[ -f "$DESTINATION" && "${1:-}" != "--force" ]]; then
  echo "NNUE already present: $DESTINATION"
  exit 0
fi

TEMP_FILE="$DESTINATION.tmp.$$"
trap 'rm -f "$TEMP_FILE"' EXIT

echo "Downloading $NNUE_FILE..."
curl -L --fail --retry 3 --retry-delay 5 "$URL" -o "$TEMP_FILE"
mv "$TEMP_FILE" "$DESTINATION"
trap - EXIT

echo "Downloaded NNUE: $DESTINATION"
