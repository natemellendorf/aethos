# ADR: Diagnostics Collector and Run-Scoped Observability

- Status: Proposed
- Date: 2026-04-21

## Context

Cross-platform LAN gossip debugging has relied on thin, platform-specific logs that do not correlate one test run across discovery, encounter setup, protocol exchange, import, and UI projection. That makes automated diagnosis slow and ambiguous.

## Decision

Adopt a shared diagnostics event schema and a collector-based diagnostics plane that is separate from the relay data plane.

### Chosen shape

- Shared event contract: `docs/spec/diagnostics-event-schema-v1.md`
- Collector implementation language: Rust
- HTTP server framework: axum
- Serialization: serde / serde_json
- Internal service logging: tracing / tracing-subscriber
- Initial storage: SQLite via sqlx
- Future storage path: Postgres via sqlx without changing the event contract

### Required system properties

- Run-scoped correlation via `run_id`
- Strongly typed request and response models derived from the shared schema
- Best-effort remote diagnostics emission that never blocks application behavior
- Local diagnostics persistence remains available when the collector is unavailable
- Privacy defaults exclude plaintext message bodies, private keys, and secrets

## Consequences

- Desktop, iOS core, and harness tooling can reconstruct one causal timeline for a run.
- AI agents can query a stable summary API instead of scraping raw logs.
- Existing local logging stays useful, but structured diagnostics becomes the canonical explainability plane.
- The collector remains operationally separate from relay transport and message delivery.

## Non-Goals

- Replacing all local logging
- Embedding diagnostics into the relay protocol data plane
- Capturing decrypted bodies or private key material
- Fixing all protocol flakiness in this decision alone
