# Gossip V1 Documentation Audit

Status: non-normative audit report for bead `aethos-nxi`.

## Scope

This audit classifies every current document asset under `docs/` and records the chosen action.

## Classification Matrix

| Path | Action | Rationale | Replacement refs |
| --- | --- | --- | --- |
| `docs/protocol/gossip.md` | Keep but update | Canonical transport-neutral architecture/invariants; added source-attribution precedence and implementation-truth note. | `docs/protocol/frames.md`, `docs/protocol/encounter.md` |
| `docs/protocol/frames.md` | Keep but update | Canonical frame catalog remains authoritative; added source-attribution cross-reference note. | `docs/protocol/gossip.md` |
| `docs/protocol/encounter.md` | Keep but update | Canonical encounter/session semantics remain authoritative; added source-attribution cross-reference note. | `docs/protocol/gossip.md` |
| `docs/protocol/replication.md` | Keep | Canonical replication/pruning semantics are aligned with active Gossip V1 invariants. | N/A |
| `docs/protocol/scoring.md` | Keep | Non-wire local policy boundary guidance remains valid and non-contradictory. | N/A |
| `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` | Keep but update | Active transport/product contract retained; removed dependency on legacy MVP0 object-format material and aligned envelope wording with canonical Gossip V1 envelope semantics. | `docs/protocol/frames.md` |
| `docs/spec/FEDERATION_PROTOCOL_V1.md` | Keep but update | Active federation/product contract retained; removed dependency on legacy MVP0 object-format material and aligned envelope wording with canonical Gossip V1 envelope semantics. | `docs/protocol/frames.md` |
| `docs/spec/RECEIPTS.md` | Keep but update | Active receipts contract retained; removed dependency on legacy MVP0 object-format material, preserved receipt semantics. | `AethosCore/Sources/AethosCore/Models/ReceiptV1.swift` |
| `docs/adr/ADR-0001-protocol-contract-source-of-truth.md` | Keep but update | Needed deconfliction to reflect canonical hierarchy (`docs/protocol/*` + `docs/spec/*`) and clarify historical/non-normative legacy material. | `README.md`, `docs/protocol/*`, `docs/spec/*` |
| `docs/adr/ADR-0002-runtime-architecture-gossip-v1.md` | Keep | Active architecture decision remains consistent with canonical Gossip V1 docs. | N/A |
| `docs/adr/ADR-0003-multi-relay-client-replication-policy.md` | Keep | Active policy ADR remains consistent with canonical Gossip V1 docs. | N/A |
| `protocol-mvp0.md` (archived) | Archive | Historical MVP0 object-format doc conflicts with active Gossip V1 transfer-envelope model (implementation and fixtures use deterministic CBOR map envelope bytes). Marked non-normative. | `docs/protocol/frames.md`, `docs/protocol/gossip.md`, `Fixtures/Protocol/gossip-v1/` |
| `relay-contract-v0.1.md` (archived) | Archive | Legacy v0.1 client-relay contract retained for history only; superseded by active v1 transport/product contract. Marked non-normative. | `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` |
| `protocol_update.md` (archived migration plan) | Archive | Migration-era planning artifact; not an active normative contract. Marked non-normative. | `docs/protocol/*`, `docs/spec/*`, `docs/adr/*` |
| `PROTOCOL_COMPATIBILITY_MATRIX.md` (archived migration matrix) | Archive | Migration scoreboard artifact; not an active normative contract. Marked non-normative. | `docs/spec/*`, `docs/protocol/*` |
| `protocol_architecture.md` (archived migration companion) | Archive | Migration companion artifact; not an active normative contract. Marked non-normative. | `docs/adr/*`, `docs/protocol/*` |
| `CLIENT_RELAY_LEGACY_CLEANUP_PLAN.md` (archived migration cleanup plan) | Archive | Migration cleanup planning artifact; not an active normative contract. Marked non-normative. | `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` |
| `CLIENT_RELAY_CONFORMANCE_FIXTURES.md` (archived migration fixture plan) | Archive | Migration fixture-planning artifact; not an active normative contract. Marked non-normative. | `Fixtures/Protocol/gossip-v1/`, `docs/spec/CLIENT_RELAY_PROTOCOL_V1.md` |
| `docs/img/banner.jpg` | Keep | Active README banner asset. | `README.md` |
| `docs/img/logo.png` | Keep | Active repository branding asset. | `README.md` |

## Notes on implementation truth check

Legacy MVP0 object-format material was archived (not rewritten) because active Gossip V1 implementation and fixture tests enforce the CBOR envelope model described in `docs/protocol/frames.md`:

- `AethosCore/Sources/AethosCore/Protocol/GossipV1/GossipV1Frames.swift` validates transfer envelope bytes as canonical CBOR map with required keys `to_wayfarer_id`, `manifest_id`, `body`.
- `AethosCore/Tests/AethosCoreTests/GossipV1FramesTests.swift` and fixture vectors in `Fixtures/Protocol/gossip-v1/*.cbor` validate deterministic CBOR frame/envelope behavior.
