#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMPLEMENTATION="$SCRIPT_DIR/make-appcast.sh"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/make-appcast-tests.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf 'FAIL %s: %s\n' "$1" "$2" >&2; }

xpath() {
    xmllint --xpath "$2" "$1" 2>/dev/null
}

NOTES="$TEMP_ROOT/notes.txt"
printf -- '- Fix memory growth & peaks <5 GB>\n\n- Faster "startup"\n' > "$NOTES"
APPCAST="$TEMP_ROOT/appcast.xml"

if bash "$IMPLEMENTATION" 0.1.2 27 15.0 \
    "https://github.com/axot/OpenSuperMLX/releases/download/0.1.2/OpenSuperMLX.dmg" \
    "c2lnbmF0dXJl==" 37123744 "$NOTES" > "$APPCAST"; then
    pass "writes an appcast"
else
    fail "writes an appcast" "script exited non-zero"
fi

if xmllint --noout "$APPCAST" 2>/dev/null; then
    pass "appcast is well-formed XML"
else
    fail "appcast is well-formed XML" "xmllint rejected it"
fi

item='/rss/channel/item'
sparkle='*[namespace-uri()="http://www.andymatuschak.org/xml-namespaces/sparkle"'
check_value() {
    local name="$1" expression="$2" expected="$3" actual
    actual="$(xpath "$APPCAST" "$expression" || true)"
    if [[ "$actual" == "$expected" ]]; then
        pass "$name"
    else
        fail "$name" "expected '$expected', got '$actual'"
    fi
}
check_value "build number is sparkle:version" "string($item/$sparkle and local-name()='version'])" "27"
check_value "tag is the short version" "string($item/$sparkle and local-name()='shortVersionString'])" "0.1.2"
check_value "minimum system version" "string($item/$sparkle and local-name()='minimumSystemVersion'])" "15.0"
check_value "enclosure URL" "string($item/enclosure/@url)" \
    "https://github.com/axot/OpenSuperMLX/releases/download/0.1.2/OpenSuperMLX.dmg"
check_value "enclosure EdDSA signature" "string($item/enclosure/@*[local-name()='edSignature'])" "c2lnbmF0dXJl=="
check_value "enclosure length" "string($item/enclosure/@length)" "37123744"

check_value "release notes use Sparkle's markdown format" \
    "string($item/description/@*[local-name()='format'])" "markdown"
description="$(xpath "$APPCAST" "string($item/description)" || true)"
if [[ "$description" == $'- Fix memory growth & peaks <5 GB>\n\n- Faster "startup"' ]]; then
    pass "release notes are the tag's markdown, unchanged"
else
    fail "release notes are the tag's markdown, unchanged" "got '$description'"
fi

printf 'Handles ]]> in notes\n' > "$NOTES"
bash "$IMPLEMENTATION" 0.1.2 27 15.0 https://example.invalid/OpenSuperMLX.dmg c2ln 1 "$NOTES" > "$APPCAST"
description="$(xpath "$APPCAST" "string($item/description)" || true)"
if xmllint --noout "$APPCAST" 2>/dev/null && [[ "$description" == 'Handles ]]> in notes' ]]; then
    pass "notes containing ]]> stay well-formed"
else
    fail "notes containing ]]> stay well-formed" "got '$description'"
fi

pub_date="$(xpath "$APPCAST" "string($item/pubDate)" || true)"
if [[ "$pub_date" =~ ^[A-Z][a-z]{2},\ [0-9]{2}\ [A-Z][a-z]{2}\ [0-9]{4}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\ \+0000$ ]]; then
    pass "pubDate uses RFC 2822"
else
    fail "pubDate uses RFC 2822" "got '$pub_date'"
fi

if bash "$IMPLEMENTATION" 0.1.2 27 15.0 > /dev/null 2>&1; then
    fail "rejects missing arguments" "script succeeded"
else
    pass "rejects missing arguments"
fi

printf '%d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
