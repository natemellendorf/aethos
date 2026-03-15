package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sort"
)

type vectorFile struct {
	Name     string   `json:"name"`
	Envelope envelope `json:"envelope"`
}

type envelope struct {
	ToWayfarerID string `json:"to_wayfarer_id"`
	ManifestID   string `json:"manifest_id"`
	BodyUTF8     string `json:"body_utf8"`
}

type output struct {
	CanonicalCBORHex string `json:"canonical_cbor_hex"`
	ItemIDHex        string `json:"item_id_hex"`
	EnvelopeB64      string `json:"envelope_b64"`
}

func main() {
	if len(os.Args) != 3 {
		fatal(errors.New("usage: go_runner encode-envelope <vector-file>"))
	}
	if os.Args[1] != "encode-envelope" {
		fatal(fmt.Errorf("unsupported command: %s", os.Args[1]))
	}

	raw, err := os.ReadFile(os.Args[2])
	if err != nil {
		fatal(err)
	}

	var vf vectorFile
	if err := json.Unmarshal(raw, &vf); err != nil {
		fatal(err)
	}

	if err := validateEnvelope(vf.Envelope); err != nil {
		fatal(err)
	}

	canonical, err := encodeCanonicalEnvelope(vf.Envelope)
	if err != nil {
		fatal(err)
	}

	h := sha256.Sum256(canonical)
	out := output{
		CanonicalCBORHex: hex.EncodeToString(canonical),
		ItemIDHex:        hex.EncodeToString(h[:]),
		EnvelopeB64:      base64.RawURLEncoding.EncodeToString(canonical),
	}

	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(out); err != nil {
		fatal(err)
	}
}

func validateEnvelope(env envelope) error {
	if len(env.ToWayfarerID) != 64 || !isHexLower(env.ToWayfarerID) {
		return errors.New("envelope.to_wayfarer_id must be 64 lowercase hex chars")
	}
	if len(env.ManifestID) != 64 || !isHexLower(env.ManifestID) {
		return errors.New("envelope.manifest_id must be 64 lowercase hex chars")
	}
	return nil
}

func isHexLower(s string) bool {
	for _, r := range s {
		if (r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') {
			continue
		}
		return false
	}
	return true
}

func encodeCanonicalEnvelope(env envelope) ([]byte, error) {
	type pair struct {
		k string
		v string
	}
	entries := []pair{
		{k: "to_wayfarer_id", v: env.ToWayfarerID},
		{k: "manifest_id", v: env.ManifestID},
		{k: "body_utf8", v: env.BodyUTF8},
	}

	sort.Slice(entries, func(i, j int) bool {
		if len(entries[i].k) != len(entries[j].k) {
			return len(entries[i].k) < len(entries[j].k)
		}
		return entries[i].k < entries[j].k
	})

	out := []byte{0xa0 | byte(len(entries))}
	for _, e := range entries {
		key, err := encodeText(e.k)
		if err != nil {
			return nil, err
		}
		val, err := encodeText(e.v)
		if err != nil {
			return nil, err
		}
		out = append(out, key...)
		out = append(out, val...)
	}
	return out, nil
}

func encodeText(s string) ([]byte, error) {
	b := []byte(s)
	n := len(b)
	switch {
	case n < 24:
		return append([]byte{0x60 | byte(n)}, b...), nil
	case n < 256:
		return append([]byte{0x78, byte(n)}, b...), nil
	case n < 65536:
		return append([]byte{0x79, byte(n >> 8), byte(n)}, b...), nil
	default:
		return nil, errors.New("string too long for compatibility runner")
	}
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}
