#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Building aethos..."
cd "$ROOT_DIR"
swift build

AE="${ROOT_DIR}/.build/debug/aethos"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PEER_A="$WORK/peerA"
PEER_B="$WORK/peerB"

echo "Initializing peers..."
"$AE" init --home "$PEER_A" >/dev/null
"$AE" init --home "$PEER_B" >/dev/null

PAYLOAD="$WORK/payload.bin"
dd if=/dev/urandom of="$PAYLOAD" bs=1024 count=200 status=none

TO_HEX="$(python3 - <<'PY'
print('aa'*32)
PY
)"

echo "Queueing send from peerA..."
SEND_OUT="$WORK/send.out"
"$AE" send --home "$PEER_A" --file "$PAYLOAD" --to "$TO_HEX" | tee "$SEND_OUT"
MANIFEST_ID="$(grep -E '^  manifestId=' "$SEND_OUT" | sed 's/^  manifestId=//')"

if [[ -z "$MANIFEST_ID" ]]; then
  echo "Failed to extract manifestId from send output" >&2
  exit 1
fi

REASSEMBLED="$PEER_B/transport/archive/reassembled-${MANIFEST_ID}.bin"

echo "Pumping/ingesting until delivered..."
for i in $(seq 1 50); do
  echo "Round $i"

  "$AE" pump --home "$PEER_A" --max-bytes 6144 --max-items 64 >/dev/null
  # Simulate file-drop transfer A -> B
  shopt -s nullglob
  for f in "$PEER_A/transport/outbox"/*; do
    mv "$f" "$PEER_B/transport/inbox/"
  done
  shopt -u nullglob

  "$AE" ingest --home "$PEER_B" --max 200 >/dev/null

  if [[ -f "$REASSEMBLED" ]]; then
    echo "Delivered. Verifying bytes..."
    A_HASH="$(shasum -a 256 "$PAYLOAD" | awk '{print $1}')"
    B_HASH="$(shasum -a 256 "$REASSEMBLED" | awk '{print $1}')"
    echo "payload sha256:      $A_HASH"
    echo "reassembled sha256:  $B_HASH"
    [[ "$A_HASH" == "$B_HASH" ]]
    echo "OK"
    exit 0
  fi
done

echo "Not delivered after 50 rounds" >&2
exit 1
