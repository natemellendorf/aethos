#!/usr/bin/env bash
# ci_smoke_filedrop.sh — fast regression guardrail for the file-drop transport.
#
# Runs a scaled-down version of demo_filedrop.sh suitable for CI:
#   - 64 KB payload (2 chunks) instead of 200 KB
#   - Delivers within ~15 rounds
#   - Fails loudly on timeout or byte-mismatch
#
# Usage:
#   ./scripts/ci_smoke_filedrop.sh          # normal run
#   KEEP_WORK=1 ./scripts/ci_smoke_filedrop.sh  # preserve work dir on exit
#
# Environment overrides:
#   BYTES=<n>     Payload size in bytes  (default: 65536)
#   ROUNDS=<n>    Max pump/ingest rounds (default: 40)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Building aethos..."
cd "$ROOT_DIR"
swift build 2>&1

AE="${ROOT_DIR}/.build/debug/aethos"

WORK="$(mktemp -d)"
if [[ "${KEEP_WORK:-0}" == "1" ]]; then
  echo "KEEP_WORK=1 — work dir preserved at: $WORK"
else
  trap 'rm -rf "$WORK"' EXIT
fi

PEER_A="$WORK/peerA"
PEER_B="$WORK/peerB"

"$AE" init --home "$PEER_A" >/dev/null
"$AE" init --home "$PEER_B" >/dev/null

TA_OUT="$PEER_A/transport/outbox"
TA_IN="$PEER_A/transport/inbox"
TA_AR="$PEER_A/transport/archive"
TB_OUT="$PEER_B/transport/outbox"
TB_IN="$PEER_B/transport/inbox"
TB_AR="$PEER_B/transport/archive"
mkdir -p "$TA_AR" "$TB_AR"

PAYLOAD_BYTES="${BYTES:-65536}"
PAYLOAD="$WORK/payload.bin"
dd if=/dev/urandom of="$PAYLOAD" bs=1 count="$PAYLOAD_BYTES" status=none

TO_HEX="$(python3 -c "print('aa'*32)")"

SEND_OUT="$WORK/send.out"
"$AE" send --home "$PEER_A" --file "$PAYLOAD" --to "$TO_HEX" | tee "$SEND_OUT"
MANIFEST_ID="$(grep -E '^  manifestId=' "$SEND_OUT" | sed 's/^  manifestId=//')"

if [[ -z "$MANIFEST_ID" ]]; then
  echo "FAIL: could not extract manifestId from send output" >&2
  exit 1
fi

REASSEMBLED="$PEER_B/transport/archive/reassembled-${MANIFEST_ID}.bin"
MAX_ROUNDS="${ROUNDS:-40}"

forward_outbox() {
  local src="$1" dst="$2"
  shopt -s nullglob
  for f in "$src"/*; do mv "$f" "$dst/"; done
  shopt -u nullglob
}

forward_archive() {
  local src="$1" dst="$2"
  shopt -s nullglob
  for f in "$src"/out-*.bin; do mv "$f" "$dst/"; done
  shopt -u nullglob
}

for i in $(seq 1 "$MAX_ROUNDS"); do
  "$AE" pump   --home "$PEER_A" --max-bytes 6144 --max-items 64 >/dev/null
  forward_outbox  "$TA_OUT" "$TB_IN"
  forward_archive "$TA_AR"  "$TB_IN"

  "$AE" ingest --home "$PEER_B" --max 200 >/dev/null

  "$AE" pump   --home "$PEER_B" --max-bytes 6144 --max-items 64 >/dev/null
  forward_outbox  "$TB_OUT" "$TA_IN"
  forward_archive "$TB_AR"  "$TA_IN"

  "$AE" ingest --home "$PEER_A" --max 200 >/dev/null

  if [[ -f "$REASSEMBLED" ]]; then
    A_HASH="$(shasum -a 256 "$PAYLOAD" | awk '{print $1}')"
    B_HASH="$(shasum -a 256 "$REASSEMBLED" | awk '{print $1}')"
    if [[ "$A_HASH" != "$B_HASH" ]]; then
      echo "FAIL: sha256 mismatch after $i rounds" >&2
      echo "  payload:     $A_HASH" >&2
      echo "  reassembled: $B_HASH" >&2
      exit 1
    fi
    echo "OK: delivered and verified in $i rounds (${PAYLOAD_BYTES} bytes, sha256=$A_HASH)"
    exit 0
  fi
done

echo "FAIL: not delivered after $MAX_ROUNDS rounds (payload=${PAYLOAD_BYTES} bytes)" >&2
exit 1
