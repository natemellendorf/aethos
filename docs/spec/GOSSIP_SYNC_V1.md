# GOSSIP_SYNC_V1 (Future)

Status: Future-facing draft inventory sync notes (non-normative)

This document sketches a possible v1 gossip/inventory sync layer that may expand pull behavior.

## Goals

- Reduce duplicate payload transfer between relays/devices
- Allow inventory-first sync (`what do you have?`) before payload fetch
- Preserve existing TTL and non-extension semantics

## Candidate Flow

1. Peer A sends inventory summary (message IDs and expiry windows).
2. Peer B responds with missing IDs only.
3. Peer A sends requested payloads.
4. Peer B acknowledges receipt and updates inventory.

## Constraints Carried Forward

- TTL remains authoritative from original creation and MUST NOT be extended.
- Expired items MUST NOT be requested or transferred.
- Any eventual sync frame set should align with `CLIENT_RELAY_PROTOCOL_V1` and `FEDERATION_PROTOCOL_V1` semantics.
