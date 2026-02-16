#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Building aethos..."
cd "$ROOT_DIR"
swift build

AE="${ROOT_DIR}/.build/debug/aethos"

WORK="$(mktemp -d)"
if [[ "${KEEP_WORK:-0}" == "1" ]]; then
  echo "KEEP_WORK=1 — work dir preserved at: $WORK"
else
  trap 'rm -rf "$WORK"' EXIT
fi

PEER_A="$WORK/peerA"
PEER_B="$WORK/peerB"

echo "Initializing peers..."
"$AE" init --home "$PEER_A" >/dev/null
"$AE" init --home "$PEER_B" >/dev/null

# Transport directories
TA_OUT="$PEER_A/transport/outbox"
TA_IN="$PEER_A/transport/inbox"
TA_AR="$PEER_A/transport/archive"
TB_OUT="$PEER_B/transport/outbox"
TB_IN="$PEER_B/transport/inbox"
TB_AR="$PEER_B/transport/archive"

# Ensure archive dirs exist
mkdir -p "$TA_AR" "$TB_AR"

PAYLOAD="$WORK/payload.bin"
dd if=/dev/urandom of="$PAYLOAD" bs=1024 count=200 status=none

TO_HEX="$($AE status --home "$PEER_B" --json-v1 2>/dev/null | python3 -c 'import json,sys; data=json.load(sys.stdin); print(data.get("identity", {}).get("wayfarer_id", ""))')"

if [[ -z "$TO_HEX" ]]; then
  echo "Failed to read peerB wayfarerId" >&2
  exit 1
fi

echo "Queueing send from peerA..."
SEND_OUT="$WORK/send.out"
"$AE" send --home "$PEER_A" --file "$PAYLOAD" --to "$TO_HEX" | tee "$SEND_OUT"
MANIFEST_ID="$(grep -E '^  manifestId=' "$SEND_OUT" | sed 's/^  manifestId=//')"

if [[ -z "$MANIFEST_ID" ]]; then
  echo "Failed to extract manifestId from send output" >&2
  exit 1
fi

REASSEMBLED="$PEER_B/transport/archive/reassembled-${MANIFEST_ID}.bin"

ROUNDS="${ROUNDS:-50}"

# ── helpers ──────────────────────────────────────────────────────────
# forward_outbox SRC_OUTBOX DST_INBOX LABEL
#   Move every file in SRC_OUTBOX to DST_INBOX.
forward_outbox() {
  local src="$1" dst="$2" label="$3"
  shopt -s nullglob
  for f in "$src"/*; do
    echo "  [$label outbox]  $(basename "$f")"
    mv "$f" "$dst/"
  done
  shopt -u nullglob
}

# forward_archive SRC_ARCHIVE DST_INBOX LABEL
#   Move only out-*.bin from SRC_ARCHIVE to DST_INBOX.
forward_archive() {
  local src="$1" dst="$2" label="$3"
  shopt -s nullglob
  for f in "$src"/out-*.bin; do
    echo "  [$label archive] $(basename "$f")"
    mv "$f" "$dst/"
  done
  shopt -u nullglob
}

# ── main loop ────────────────────────────────────────────────────────
echo "Pumping/ingesting until delivered (max $ROUNDS rounds)..."
for i in $(seq 1 "$ROUNDS"); do
  echo "── Round $i ──"

  # 1. Pump peerA — push outbound frames into A/outbox
  "$AE" pump --home "$PEER_A" --max-bytes 6144 --max-items 64 >/dev/null

  # 2. Forward A → B (outbox + archive out-*.bin)
  forward_outbox  "$TA_OUT" "$TB_IN" "A→B"
  forward_archive "$TA_AR"  "$TB_IN" "A→B"

  # 3. Ingest on peerB
  "$AE" ingest --home "$PEER_B" --max 200 >/dev/null

  # 4. Pump peerB — push acks/receipts into B/outbox
  "$AE" pump --home "$PEER_B" --max-bytes 6144 --max-items 64 >/dev/null

  # 5. Forward B → A (outbox + archive out-*.bin)
  forward_outbox  "$TB_OUT" "$TA_IN" "B→A"
  forward_archive "$TB_AR"  "$TA_IN" "B→A"

  # 6. Ingest on peerA (process acks)
  "$AE" ingest --home "$PEER_A" --max 200 >/dev/null

  # 7. Check for reassembled file
  if [[ -f "$REASSEMBLED" ]]; then
    echo ""
    echo "Delivered ✅"
    echo "Verifying bytes..."
    A_HASH="$(shasum -a 256 "$PAYLOAD" | awk '{print $1}')"
    B_HASH="$(shasum -a 256 "$REASSEMBLED" | awk '{print $1}')"
    echo "payload sha256:      $A_HASH"
    echo "reassembled sha256:  $B_HASH"
    [[ "$A_HASH" == "$B_HASH" ]]
    echo "OK ✅"
    exit 0
  fi
done

echo "Not delivered after $ROUNDS rounds" >&2
exit 1
