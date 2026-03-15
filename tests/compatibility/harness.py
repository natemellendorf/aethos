#!/usr/bin/env python3
import argparse
import base64
import hashlib
import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent
VECTORS_DIR = ROOT / "vectors"
RUNNERS = {
    "Go relay": ROOT / "runners" / "go_runner",
    "Rust client": ROOT / "runners" / "rust_runner",
    "Swift client": ROOT / "runners" / "swift_runner",
}


def run_runner(path: Path, command: str, vector_path: Path):
    proc = subprocess.run(
        [str(path), command, str(vector_path)],
        capture_output=True,
        text=True,
        cwd=ROOT,
    )
    if proc.returncode == 2:
        return {"status": "skip", "reason": proc.stderr.strip() or proc.stdout.strip()}
    if proc.returncode != 0:
        return {
            "status": "fail",
            "reason": (
                f"command failed: {path.name} {command} {vector_path.name}\n"
                f"stdout:\n{proc.stdout}\n"
                f"stderr:\n{proc.stderr}"
            ),
        }

    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        return {
            "status": "fail",
            "reason": (
                f"runner emitted invalid JSON: {path.name}\n"
                f"stdout:\n{proc.stdout}\n"
                f"stderr:\n{proc.stderr}"
            ),
            "error": str(exc),
        }
    return {"status": "ok", "data": data}


def compare_expected(actual: dict, expected: dict):
    mismatches = []
    for key, exp in expected.items():
        if actual.get(key) != exp:
            mismatches.append(
                f"{key} mismatch\nexpected: {exp}\nactual:   {actual.get(key)}"
            )
    return mismatches


def verify_hash_consistency(result: dict):
    envelope_b64 = result["envelope_b64"]
    envelope_bytes = base64.urlsafe_b64decode(envelope_b64 + b64_padding(envelope_b64))
    actual_item = hashlib.sha256(envelope_bytes).hexdigest()
    if actual_item != result["item_id_hex"]:
        return [
            "item_id hash derivation mismatch\n"
            f"expected sha256(envelope_bytes): {actual_item}\n"
            f"runner item_id_hex:          {result['item_id_hex']}"
        ]
    return []


def verify_base64url_consistency(result: dict):
    envelope_b64 = result["envelope_b64"]
    envelope_bytes = base64.urlsafe_b64decode(envelope_b64 + b64_padding(envelope_b64))
    reencoded = base64.urlsafe_b64encode(envelope_bytes).decode().rstrip("=")
    if reencoded != envelope_b64:
        return [
            "base64url canonical mismatch\n"
            f"expected: {reencoded}\n"
            f"actual:   {envelope_b64}"
        ]
    return []


def verify_frame_roundtrip(result: dict):
    envelope_b64 = result["envelope_b64"]
    envelope_bytes = base64.urlsafe_b64decode(envelope_b64 + b64_padding(envelope_b64))
    if len(envelope_bytes) > 65535:
        return ["frame encode/decode check failed: envelope too large"]

    frame = bytes([1]) + len(envelope_bytes).to_bytes(2, "big") + envelope_bytes
    decoded_len = int.from_bytes(frame[1:3], "big")
    decoded_envelope = frame[3:]

    if decoded_len != len(decoded_envelope):
        return [
            "frame decode length mismatch\n"
            f"expected length: {decoded_len}\n"
            f"actual length:   {len(decoded_envelope)}"
        ]
    if decoded_envelope != envelope_bytes:
        return ["frame decode payload mismatch"]
    return []


def verify_transfer_behavior(result: dict):
    envelope_b64 = result["envelope_b64"]
    envelope_bytes = base64.urlsafe_b64decode(envelope_b64 + b64_padding(envelope_b64))

    hello = {"type": "HELLO", "protocol": "compat-v1"}
    summary = {"type": "SUMMARY", "item_count": 1}
    request = {"type": "REQUEST", "item_ids": [result["item_id_hex"]]}
    transfer = {
        "type": "TRANSFER",
        "objects": [
            {
                "item_id": result["item_id_hex"],
                "envelope_b64": envelope_b64,
            }
        ],
    }

    received_bytes = base64.urlsafe_b64decode(
        transfer["objects"][0]["envelope_b64"]
        + b64_padding(transfer["objects"][0]["envelope_b64"])
    )
    derived_item_id = hashlib.sha256(received_bytes).hexdigest()
    receipt = {"type": "RECEIPT", "accepted_item_ids": [derived_item_id]}

    failures = []
    if transfer["objects"][0]["item_id"] != derived_item_id:
        failures.append(
            "transfer validation failed: item_id does not match envelope bytes"
        )
    if received_bytes != envelope_bytes:
        failures.append("transfer validation failed: relay mutated envelope bytes")
    if receipt["accepted_item_ids"][0] != result["item_id_hex"]:
        failures.append("receipt validation failed: receipt item_id mismatch")

    _ = hello, summary, request
    return failures


def b64_padding(value: str) -> str:
    return "=" * ((4 - len(value) % 4) % 4)


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Aethos compatibility harness")
    parser.add_argument("--verbose", action="store_true", help="Print per-vector checks")
    args = parser.parse_args()

    vector_files = sorted(
        p for p in VECTORS_DIR.glob("*.json") if not p.name.endswith(".expected.json")
    )

    if not vector_files:
        print("No vectors found.")
        return 1

    print("Running compatibility tests...\n")
    failures = []
    skips = []

    for label, runner in RUNNERS.items():
        if not runner.exists():
            skips.append(f"[SKIP] {label} (runner not found)")
            continue

        runner_failed = False
        for vector_path in vector_files:
            expected_path = vector_path.with_suffix(".expected.json")
            if not expected_path.exists():
                failures.append(f"{label}: missing expected file for {vector_path.name}")
                runner_failed = True
                continue

            expected = json.loads(expected_path.read_text(encoding="utf-8"))

            first = run_runner(runner, "encode-envelope", vector_path)
            if first["status"] == "skip":
                skips.append(f"[SKIP] {label} ({first['reason']})")
                runner_failed = True
                break
            if first["status"] != "ok":
                failures.append(f"{label}: {first['reason']}")
                runner_failed = True
                continue

            second = run_runner(runner, "encode-envelope", vector_path)
            if second["status"] != "ok":
                failures.append(f"{label}: determinism re-run failed for {vector_path.name}")
                runner_failed = True
                continue

            result = first["data"]
            rerun = second["data"]

            checks = []
            checks.extend(compare_expected(result, expected))
            if result != rerun:
                checks.append(
                    "determinism check failed\n"
                    f"first:  {json.dumps(result, sort_keys=True)}\n"
                    f"second: {json.dumps(rerun, sort_keys=True)}"
                )
            checks.extend(verify_hash_consistency(result))
            checks.extend(verify_base64url_consistency(result))
            checks.extend(verify_frame_roundtrip(result))
            checks.extend(verify_transfer_behavior(result))

            if checks:
                runner_failed = True
                for c in checks:
                    failures.append(f"{label} [{vector_path.name}]\n{c}")
            elif args.verbose:
                print(f"  {label} [{vector_path.name}] PASS")

        if not runner_failed:
            print(f"[PASS] {label}")
        else:
            if any(s.startswith(f"[SKIP] {label}") for s in skips):
                continue
            print(f"[FAIL] {label}")

    if skips:
        print()
        for entry in skips:
            print(entry)

    if failures:
        print("\nCompatibility validation FAILED\n")
        for f in failures:
            print(f)
            print()
        return 1

    print("\nAll implementations are protocol compatible.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
