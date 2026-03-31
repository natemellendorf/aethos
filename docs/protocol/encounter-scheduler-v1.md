# Encounter Scheduler Behavioral Contract (v1)

Status: normative scheduling contract for transport-neutral encounter ranking and selection.

## 1. Normative language and scope

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are to be interpreted as in RFC 2119.

This contract defines deterministic ranking/selection behavior for a constrained encounter. It does **not** change wire schema, validity, acceptance, identity, hashing, or expiry correctness rules in other protocol contracts.

## 2. Deterministic model

Scheduler inputs are:

- encounter class,
- budget profile,
- `nowUnixMs`,
- candidate cargo items.

Outputs are:

- deterministic total ranking of eligible items,
- selected prefix constrained by budget profile,
- per-item score breakdown,
- deterministic stop reason,
- optional tie-break reason for adjacent equal-score decisions.

## 3. Hard tier-first ordering (global)

Hard tiers are the primary global ordering. Weighted scoring applies only inside a tier.

Tier order (ascending priority number):

- tier 0: control/receipts/checkpoints/resumability
- tier 1: tiny endangered destination-relevant message items
- tier 2: tiny endangered transit items not for peer
- tier 3: manifests/metadata for larger objects
- tier 4: message bodies/small attachments
- tier 5: large media chunks

A higher tier number MUST NEVER displace a lower tier number item when both are eligible.

## 4. Defaults and constants (v1)

- `targetReplicaCountDefault = 6`
- `expiryUrgencyHorizonMs = 900000` (15 minutes)
- `stagnationHorizonMs = 3600000` (60 minutes)
- `preferredTransferUnitBytes = 32768`
- `clockSkewToleranceMs = 30000` (aligns with encounter expiry semantics)
- `scoreComponentScale = 1000000` (fixed-point millionths)
- `scoreEpsilon = 1e-9` (float interoperability guidance only)

## 5. Eligibility and missing-value handling

### 5.1 Mandatory fields

Each candidate item MUST include:

- `itemID` (64 lowercase hex chars),
- `tier` (0..5),
- `sizeBytes` (integer >= 1),
- `expiryAtUnixMs` (uint64 ms epoch),
- `destinationRank` (integer >= 0).

Candidates missing mandatory fields are ineligible and MUST be excluded before ranking.

`cargoItems` MUST contain unique `itemID` values. Duplicate `itemID` entries are invalid input and MUST be rejected before ranking.

### 5.2 Expiry gate

If `nowUnixMs + clockSkewToleranceMs >= expiryAtUnixMs`, candidate is expired and ineligible.

### 5.3 Defaults for optional fields

When optional scoring fields are missing, implementations MUST apply these defaults:

- `knownReplicaCount = 0`
- `targetReplicaCount = targetReplicaCountDefault`
- `durablyStored = false`
- `relayIngested = false`
- `receiptCoverage = 0.0`
- `lastForwardedAtUnixMs = 0` (treated as very old / never forwarded)
- `explicitUserInitiated = false`
- `proximityClass = "other"`
- `contentClassScore = 0.0`

All numeric normalization inputs MUST be clamped to `[0, 1]` after derivation.

## 6. Canonical normalization rules

Define `clamp01(x) = min(max(x, 0), 1)`.

### 6.1 Scarcity

`targetReplicaCount = max(1, targetReplicaCount)`

`scarcityScore = 1 - min(knownReplicaCount / targetReplicaCount, 1)`

Then `scarcityScore = clamp01(scarcityScore)`.

### 6.2 Safety

Safety urgency is composed from not durably stored, not relay-ingested, and weak receipt coverage:

- `durableRisk = durablyStored ? 0 : 1`
- `relayRisk = relayIngested ? 0 : 1`
- `receiptCoverage = clamp01(receiptCoverage)`
- `receiptRisk = 1 - receiptCoverage`

`safetyScore = clamp01(durableRisk*0.45 + relayRisk*0.35 + receiptRisk*0.20)`

### 6.3 Expiry

- `ttlMs = max(expiryAtUnixMs - nowUnixMs, 0)`
- `expiryScore = 1 - min(ttlMs / expiryUrgencyHorizonMs, 1)`
- `expiryScore = clamp01(expiryScore)`

This rises as TTL approaches zero within the configured horizon.

### 6.4 Stagnation

- `idleMs = max(nowUnixMs - lastForwardedAtUnixMs, 0)`
- `stagnationScore = min(idleMs / stagnationHorizonMs, 1)`
- `stagnationScore = clamp01(stagnationScore)`

This rises with time since last forward within the configured horizon.

### 6.5 Proximity

Map proximity class to score:

- `"destination-peer"`: `1.0`
- `"likely-closer"`: `0.6`
- `"other"`: `0.0`

### 6.6 Size

Size score uses a logarithmic curve against preferred transfer unit:

`sizeScore = 1 - min( ln(1 + sizeBytes) / ln(1 + preferredTransferUnitBytes), 1 )`

Then `sizeScore = clamp01(sizeScore)`.

### 6.7 Intent

`intentScore = explicitUserInitiated ? 1.0 : 0.0`

### 6.8 Content class

`contentClassScore` is a minor intra-tier nudge only.

- Input must be clamped to `[0,1]`.
- It MUST NOT be used to move items across tiers.

## 7. Canonical weighted score (within a tier)

Within the same tier only, score MUST be computed as:

`score = scarcity*0.26 + safety*0.22 + expiry*0.16 + stagnation*0.12 + proximity*0.10 + size*0.08 + intent*0.04 + contentClass*0.02`

## 8. Cross-language numeric determinism

Implementations SHOULD avoid direct float comparison and use fixed-point integers.

### 8.1 Canonical fixed-point procedure

1. Compute each component as real and clamp to `[0,1]`.
2. Quantize each component into millionths:
   - `componentU = roundHalfEven(component * 1_000_000)`
   - clamp to `0..1_000_000`.
3. Compute integer weighted numerator:

`scoreNumerator = scarcityU*26 + safetyU*22 + expiryU*16 + stagnationU*12 + proximityU*10 + sizeU*8 + intentU*4 + contentClassU*2`

4. Canonical decimal score for diagnostics:

`score = scoreNumerator / 100_000_000`

Ordering MUST compare `scoreNumerator` integers (not floats).

### 8.2 Epsilon guidance

If an implementation must compare floating-point diagnostic scores, values with absolute difference `<= scoreEpsilon` MUST be treated as equal and tie-breakers MUST apply.

## 9. Deterministic total ordering chain

For any two eligible items `A` and `B`, compare in this exact sequence:

1. tier ascending
2. score descending
3. smaller `sizeBytes` first
4. earlier `expiryAtUnixMs` first
5. lower `knownReplicaCount` first
6. older `lastForwardedAtUnixMs` first
7. higher `destinationRank` first
8. compare `itemID` in bytewise lexicographic order of decoded 32-byte digest (equivalently ASCII lexicographic order of 64-char lowercase hex), with higher value first (descending)

Rule 8 therefore ranks lexicographically smaller `itemID` values last.

## 10. Selection prefix and stop reason

After deterministic ranking, select items in order until adding the next item would violate budget profile constraints.

Budget constraints MAY include:

- `maxItems`
- `maxBytes`
- `maxDurationMs` (planner estimate)
- `durableCargoRatioCap` (ratio for tier 4/5 bytes)

Canonical stop reasons:

- `completed`
- `budget-items-exhausted`
- `budget-bytes-exhausted`
- `encounter-time-exhausted`
- `durable-ratio-cap-reached`
- `no-eligible-items`

## 11. Worked examples (exact ordering decisions)

All examples use `targetReplicaCount=6`, `expiryUrgencyHorizonMs=900000`, `stagnationHorizonMs=3600000`, `preferredTransferUnitBytes=32768`.

### Example 1: hard tier dominance over weighted score

- Item `A` (tier 1): score `0.120000`
- Item `B` (tier 2): score `0.990000`

Result: `A` ranks before `B` because tier ordering is global and absolute.

### Example 2: weighted within-tier ranking

Same tier (tier 3), same size/expiry/replicas/lastForwarded/destinationRank for clarity.

- Item `C` components: scarcity `0.833333`, safety `1.000000`, expiry `0.800000`, stagnation `0.500000`, proximity `0.600000`, size `0.400000`, intent `0.000000`, contentClass `0.300000`
  - `score(C) = 0.21666658 + 0.22000000 + 0.12800000 + 0.06000000 + 0.06000000 + 0.03200000 + 0.00000000 + 0.00600000 = 0.72266658`
- Item `D` components: scarcity `0.666667`, safety `0.800000`, expiry `0.900000`, stagnation `0.500000`, proximity `0.600000`, size `0.400000`, intent `1.000000`, contentClass `0.300000`
  - `score(D) = 0.17333342 + 0.17600000 + 0.14400000 + 0.06000000 + 0.06000000 + 0.03200000 + 0.04000000 + 0.00600000 = 0.69133342`

Result: `C` ranks before `D` (higher within-tier score).

### Example 3: tie-break chain to deterministic winner

Two tier-4 items `E` and `F` with identical `scoreNumerator`, `sizeBytes`, `expiryAtUnixMs`, `knownReplicaCount`, and `lastForwardedAtUnixMs`.

- `destinationRank(E)=3`, `destinationRank(F)=5`

Result: `F` ranks first (higher destination rank).

If destination rank is also equal and `itemID(E)="0aa..."`, `itemID(F)="0ab..."`, then `F` still ranks first because the `itemID` comparator is descending bytewise/hex lexicographic order.

## 12. Fixture contract

Fixture schema is versioned and language-neutral at:

- `Fixtures/Routing/encounter-ranking/schema.json`

Fixtures MUST include at least:

- encounter class
- budget profile
- cargo items
- expected ranking order
- expected selected prefix
- expected score breakdowns
- expected stop reason
- expected tie-break reason (if any)

Fixture precision requirements:

- `components` values are post-quantization diagnostic decimals at 6 decimal places (millionths).
- `score` is a diagnostic decimal derived from `scoreNumerator` at 8 decimal places.
- `scoreNumerator` is authoritative for deterministic comparisons and expected fixture assertions.
