#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMPLEMENTATION="$SCRIPT_DIR/verify-ed-signature.swift"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/verify-ed-signature-tests.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf 'FAIL %s: %s\n' "$1" "$2" >&2; }

ARCHIVE="$TEMP_ROOT/update.dmg"
head -c 65536 /dev/urandom > "$ARCHIVE"

# Prints "<public-key> <signature> <other-public-key>" for ARCHIVE, all base64.
cat > "$TEMP_ROOT/sign.swift" <<'SWIFT'
import CryptoKit
import Foundation

let data = FileManager.default.contents(atPath: CommandLine.arguments[1])!
let key = Curve25519.Signing.PrivateKey()
let signature = try! key.signature(for: data)
let other = Curve25519.Signing.PrivateKey().publicKey
print(key.publicKey.rawRepresentation.base64EncodedString(), signature.base64EncodedString(), other.rawRepresentation.base64EncodedString())
SWIFT
swiftc -o "$TEMP_ROOT/sign" "$TEMP_ROOT/sign.swift"
swiftc -o "$TEMP_ROOT/verify" "$IMPLEMENTATION"
read -r PUBLIC_KEY SIGNATURE OTHER_PUBLIC_KEY < <("$TEMP_ROOT/sign" "$ARCHIVE")

expect_exit() {
    local name="$1" expected="$2" actual=0
    shift 2
    "$TEMP_ROOT/verify" "$@" > /dev/null 2>&1 || actual=$?
    if [[ "$actual" -eq "$expected" ]]; then
        pass "$name"
    else
        fail "$name" "expected exit $expected, got $actual"
    fi
}

expect_exit "accepts a signature made with the matching key" 0 "$PUBLIC_KEY" "$SIGNATURE" "$ARCHIVE"
expect_exit "rejects a signature checked against another key" 1 "$OTHER_PUBLIC_KEY" "$SIGNATURE" "$ARCHIVE"

TAMPERED="$TEMP_ROOT/tampered.dmg"
cp "$ARCHIVE" "$TAMPERED"
printf 'x' >> "$TAMPERED"
expect_exit "rejects a modified archive" 1 "$PUBLIC_KEY" "$SIGNATURE" "$TAMPERED"
expect_exit "rejects a public key that is not base64" 64 "not-base64!" "$SIGNATURE" "$ARCHIVE"
expect_exit "rejects missing arguments" 64 "$PUBLIC_KEY" "$SIGNATURE"

printf '%d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
