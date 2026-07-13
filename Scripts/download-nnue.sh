#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EVALUATE_HEADER="$REPO_ROOT/ThirdParty/Stockfish/src/evaluate.h"
NNUE_DIR="$REPO_ROOT/Resources/NNUE"

if [[ $# -gt 1 || ( $# -eq 1 && "${1:-}" != "--force" ) ]]; then
  echo "Usage: $0 [--force]" >&2
  exit 64
fi

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

EXPECTED_HASH_PREFIX="${NNUE_FILE#nn-}"
EXPECTED_HASH_PREFIX="${EXPECTED_HASH_PREFIX%.nnue}"
if [[ ! "$EXPECTED_HASH_PREFIX" =~ ^[0-9a-f]{12}$ ]]; then
  echo "Unexpected NNUE hash prefix in filename: $NNUE_FILE" >&2
  exit 1
fi

sha256_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    echo "Neither shasum nor sha256sum is available to verify the NNUE file" >&2
    return 1
  fi
}

verify_nnue() {
  local path="$1"
  local actual_hash
  actual_hash="$(sha256_file "$path")" || return 1
  [[ "${actual_hash:0:${#EXPECTED_HASH_PREFIX}}" == "$EXPECTED_HASH_PREFIX" ]]
}

mkdir -p "$NNUE_DIR"

DESTINATION="$NNUE_DIR/$NNUE_FILE"
URL="https://tests.stockfishchess.org/api/nn/$NNUE_FILE"

if [[ -f "$DESTINATION" && "${1:-}" != "--force" ]]; then
  if verify_nnue "$DESTINATION"; then
    echo "NNUE already present and verified: $DESTINATION"
    exit 0
  fi
  echo "Existing NNUE failed SHA-256 verification; downloading a replacement" >&2
fi

TEMP_FILE="$DESTINATION.tmp.$$"
trap 'rm -f "$TEMP_FILE"' EXIT

echo "Downloading $NNUE_FILE..."
curl --proto '=https' --tlsv1.2 --location --fail --show-error --retry 3 --retry-delay 5 \
  "$URL" -o "$TEMP_FILE"
if ! verify_nnue "$TEMP_FILE"; then
  echo "Downloaded NNUE failed SHA-256 prefix check ($EXPECTED_HASH_PREFIX)" >&2
  exit 1
fi
mv "$TEMP_FILE" "$DESTINATION"
trap - EXIT

echo "Downloaded and verified NNUE: $DESTINATION"
