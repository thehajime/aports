#!/bin/sh
# Literal source substitutions: no shell evaluation or regular-expression quoting.
# The caller supplies BEFORE/AFTER; validate counts before replacing the file.
set -eu
[ "$#" -eq 1 ] || { echo "Usage: BEFORE=... AFTER=... $0 FILE" >&2; exit 2; }
: "${BEFORE:?}" "${AFTER?}"
target=$1
temporary=$(mktemp "${target}.XXXXXX")
trap 'rm -f "$temporary"' EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
awk '
{ text = text $0 ORS }
END {
    before = ENVIRON["BEFORE"]; after = ENVIRON["AFTER"]; count = 0; output = ""
    while ((position = index(text, before)) > 0) {
        output = output substr(text, 1, position - 1) after
        text = substr(text, position + length(before)); count++
    }
    expected = ENVIRON["EXPECTED"]
    if ((expected == "" && count != 1) || (expected != "" && expected != "any" && count != expected)) {
        print "Unexpected literal source match count: " count > "/dev/stderr"
        exit 1
    }
    printf "%s", output text
}' "$target" > "$temporary"
cat "$temporary" > "$target"
