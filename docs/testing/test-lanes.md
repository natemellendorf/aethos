# Test lanes (Phase 1)

Phase 1 introduces explicit, runnable test lanes:

- **MVP0 lane (default)**: all standard tests for MVP0 scope.
- **Extended lane**: relay/zephyr-heavy suites retained and runnable, but moved out of the default lane.

## Lane definitions

- `AethosCoreTests` + other default test targets are in the MVP0 lane.
- Relay-heavy suites are in `AethosCoreExtendedTests`:
  - `RelayTransportTests`
  - `RelayLinkTests`
  - `RelayForwardingTests`
- MVP0 lane also skips relay-focused CLI snapshot tests by regex matching
  `AethosCLITests\..*[Rr]elay.*` against `swift test list` names.

## Commands

Run MVP0 lane:

```bash
scripts/test-lanes.sh mvp0
```

Run extended lane:

```bash
scripts/test-lanes.sh extended
```

Show soft scope report (non-blocking):

```bash
scripts/test-lanes.sh report
```

The report is intentionally informational only and does **not** fail CI.

## Notes

- This pass does not delete relay tests.
- The split is incremental: lane membership is target-based and preserves existing test files/styles.
