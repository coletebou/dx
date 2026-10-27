#!/usr/bin/env bash
# sync-labels.sh: make a GitHub repository's labels match labels.yml, through gh.
#
#   sync-labels.sh --repo OWNER/NAME --dry-run   the plan: what it would create, edit and delete
#   sync-labels.sh --repo OWNER/NAME             apply it
#   sync-labels.sh --repo OWNER/NAME --prune     also delete the labels labels.yml does not name
#   sync-labels.sh --print                       the parsed labels.yml as JSON (no gh, no network)
#
# Options:
#   --file PATH   the label file (default: labels.yml next to this script)
#   --dry-run     print the plan and change nothing (-n)
#   --prune       delete the repository's labels that the file does not name; without it they
#                 are listed and kept. A label in use is removed from its issues and PRs.
#
# Creates the labels the repository lacks and edits those whose color, description or letter case
# differ (GitHub matches names case-insensitively, and a color in any case). Running it again after
# a sync changes nothing. labels.yml is a YAML list of {name, color, description} mappings (see its
# header); this script reads that flat format itself, so it needs bash (3.2 is fine), python3, and
# gh logged in with write access to the repository (gh auth login). A failed write is reported and
# the rest still run.
#
# Exit status: 0 in sync or synced, 1 an error or a failed write, 2 a usage error.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
file="$here/labels.yml" repo="" dry_run=0 prune=0 print=0
limit=1000  # gh label list --limit: a repository with this many labels is refused, not half-synced

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
die() { printf 'sync-labels: %s\n' "$*" >&2; exit 1; }
usage_error() { printf 'sync-labels: %s (see --help)\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)    [ $# -ge 2 ] || usage_error "--repo needs OWNER/NAME"; repo="$2"; shift 2 ;;
        --repo=*)  repo="${1#--repo=}"; shift ;;
        --file)    [ $# -ge 2 ] || usage_error "--file needs a path"; file="$2"; shift 2 ;;
        --file=*)  file="${1#--file=}"; shift ;;
        --dry-run|-n) dry_run=1; shift ;;
        --prune)   prune=1; shift ;;
        --print)   print=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)         usage_error "unknown argument: $1" ;;
    esac
done
if [ "$print" -eq 0 ]; then
    [ -n "$repo" ] || usage_error "--repo OWNER/NAME is required"
    case "$repo" in
        */*/*|/*|*/) usage_error "--repo must be OWNER/NAME, not: $repo" ;;
        */*) ;;
        *) usage_error "--repo must be OWNER/NAME, not: $repo" ;;
    esac
    case "$repo" in *[!A-Za-z0-9_./-]*) usage_error "--repo must be OWNER/NAME, not: $repo" ;; esac
fi
command -v python3 >/dev/null 2>&1 || die "python3 is required (it reads labels.yml)"
[ -f "$file" ] && [ -r "$file" ] || die "cannot read $file"

# The planner: parses labels.yml, and compares it with the repository's labels. One file, so the
# script can be copied anywhere on its own.
read -r -d '' PLANNER <<'PY' || true
import json
import re
import sys
from urllib.parse import quote

KEYS = ("name", "color", "description")
# Plain (unquoted) scalars YAML would read as something other than a string: null, booleans
# (YAML 1.1 and 1.2), and numbers. Such a value must be quoted.
NOT_A_STRING = re.compile(
    r"^(?:~|null|Null|NULL|y|Y|yes|Yes|YES|n|N|no|No|NO|true|True|TRUE|false|False|FALSE"
    r"|on|On|ON|off|Off|OFF"
    r"|[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])*"
    r"|0o[0-7_]+|[-+]?0x[0-9a-fA-F_]+|[-+]?0b[01_]+"
    r"|[-+]?(?:\.[0-9_]+|[0-9][0-9_]*(?:\.[0-9_]*)?)(?:[eE][-+]?[0-9]+)?"
    r"|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))$")
ESCAPES = {'"': '"', "\\": "\\", "/": "/", "n": "\n", "t": "\t", "r": "\r", "0": "\0", " ": " "}


class Bad(Exception):
    pass


def after_value(rest):
    rest = rest.strip()
    if rest and not rest.startswith("#"):
        raise Bad("unexpected text after the closing quote: " + rest)


def scalar(text):
    """One YAML scalar on one line: double-quoted, single-quoted, or plain."""
    text = text.strip()
    if text.startswith('"'):
        out, i = [], 1
        while i < len(text):
            c = text[i]
            if c == "\\":
                i += 1
                e = text[i:i + 1]
                if e in ESCAPES:
                    out.append(ESCAPES[e])
                elif e in ("x", "u", "U"):
                    n = {"x": 2, "u": 4, "U": 8}[e]
                    digits = text[i + 1:i + 1 + n]
                    if not re.fullmatch(r"[0-9a-fA-F]{%d}" % n, digits):
                        raise Bad("bad \\%s escape" % e)
                    out.append(chr(int(digits, 16)))
                    i += n
                else:
                    raise Bad("unsupported escape \\" + e)
            elif c == '"':
                after_value(text[i + 1:])
                return "".join(out)
            else:
                out.append(c)
            i += 1
        raise Bad("unterminated double-quoted string (values must fit on one line)")
    if text.startswith("'"):
        out, i = [], 1
        while i < len(text):
            if text[i] == "'":
                if text[i + 1:i + 2] == "'":
                    out.append("'")
                    i += 2
                    continue
                after_value(text[i + 1:])
                return "".join(out)
            out.append(text[i])
            i += 1
        raise Bad("unterminated single-quoted string (values must fit on one line)")
    m = re.search(r"\s#", text)
    if m:
        text = text[:m.start()].rstrip()
    if text == "":
        return None
    if text[0] in "[]{}&*!|>%@`,?#" or text.startswith("- ") or ": " in text or text.endswith(":"):
        raise Bad("quote this value: %s" % text)
    if NOT_A_STRING.match(text):
        raise Bad("quote this value: YAML reads %s as a number, a boolean or null" % text)
    return text


def parse(path):
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except (OSError, UnicodeDecodeError) as e:
        raise SystemExit("sync-labels: cannot read %s: %s" % (path, e))
    items, item, key_col = [], None, None

    def fail(lineno, msg):
        raise SystemExit("sync-labels: %s:%d: %s" % (path, lineno, msg))

    def pair(lineno, text):
        m = re.match(r"([A-Za-z_][A-Za-z0-9_-]*):(?:[ \t]+(.*))?$", text)
        if not m:
            fail(lineno, "expected KEY: VALUE, got: " + text.strip())
        key = m.group(1)
        if key not in KEYS:
            fail(lineno, "unknown key %r (the keys are name, color and description)" % key)
        if key in item:
            fail(lineno, "%s given twice for one label" % key)
        try:
            item[key] = scalar(m.group(2) or "")
        except Bad as e:
            fail(lineno, str(e))
        item["_lines"][key] = lineno

    for lineno, line in enumerate(lines, 1):
        if lineno == 1 and line.startswith("\ufeff"):
            line = line[1:]
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if line.startswith("\t") or re.match(r" *\t", line):
            fail(lineno, "indent with spaces, not tabs")
        if stripped == "---" and not items and item is None:
            continue
        if stripped == "...":
            break
        if line.startswith("-") and (len(line) == 1 or line[1] in " \t"):
            rest = line[1:]
            item = {"_line": lineno, "_lines": {}}
            items.append(item)
            body = rest.lstrip(" ")
            key_col = 1 + len(rest) - len(body)
            if body.startswith("{"):
                fail(lineno, "write each label as a block mapping (name:, color:, description: on their own lines)")
            if body and not body.startswith("#"):
                pair(lineno, body)
            continue
        if line.startswith(" "):
            col = len(line) - len(line.lstrip(" "))
            if item is None:
                fail(lineno, "the file must be a list: each label starts with '- name: ...' at the start of a line")
            if col != key_col:
                fail(lineno, "indent this key to column %d, like the label's first key" % (key_col + 1))
            pair(lineno, line[col:])
            continue
        fail(lineno, "the file must be a list: each label starts with '- name: ...' at the start of a line")

    if not items:
        raise SystemExit("sync-labels: %s defines no labels" % path)
    labels, seen = [], {}
    for it in items:
        line = it["_line"]
        name, color, desc = it.get("name"), it.get("color"), it.get("description")
        if not name:
            fail(line, "a label needs a name")
        if len(name) > 50:
            fail(it["_lines"]["name"], "name %r is longer than 50 characters" % name)
        if color is None:
            fail(line, "label %r needs a color" % name)
        if color.startswith("#"):
            fail(it["_lines"]["color"], "color %r: drop the leading #" % color)
        if not re.fullmatch(r"[0-9a-fA-F]{6}", color):
            fail(it["_lines"]["color"], "color %r is not six hex digits" % color)
        desc = desc or ""
        for key, value in (("name", name), ("description", desc)):
            if re.search(r"[\x00-\x1f\x7f]", value):
                fail(it["_lines"][key], "the %s of %r has a control character" % (key, name))
        if len(desc) > 100:
            fail(it["_lines"]["description"], "the description of %r is longer than 100 characters" % name)
        low = name.lower()
        if low in seen:
            fail(line, "label %r is already defined on line %d (names are case-insensitive)" % (name, seen[low]))
        seen[low] = line
        labels.append({"name": name, "color": color, "description": desc})
    return labels


def show(s):
    return json.dumps(s, ensure_ascii=False)


def plan(labels, current_path, repo, prune, limit, commands_path):
    with open(current_path, encoding="utf-8") as f:
        current = json.load(f)
    if len(current) >= limit:
        raise SystemExit("sync-labels: %s has %d or more labels, more than this script lists; nothing done" % (repo, limit))
    have = {}
    for c in current:
        have[c["name"].lower()] = {"name": c["name"], "color": c.get("color") or "",
                                   "description": c.get("description") or ""}
    base = "repos/%s/labels" % repo
    commands, extras = [], []
    creates = edits = deletes = 0
    for lab in labels:
        cur = have.get(lab["name"].lower())
        fields = ["-f", "color=" + lab["color"], "-f", "description=" + lab["description"]]
        if cur is None:
            creates += 1
            commands.append(("create  %s  color %s, description %s" % (show(lab["name"]), lab["color"], show(lab["description"])),
                             ["api", "--method", "POST", base, "-f", "name=" + lab["name"]] + fields))
            continue
        changes = []
        if cur["name"] != lab["name"]:
            changes.append("name %s -> %s" % (show(cur["name"]), show(lab["name"])))
        if cur["color"].lower() != lab["color"].lower():
            changes.append("color %s -> %s" % (cur["color"], lab["color"]))
        if cur["description"] != lab["description"]:
            changes.append("description %s -> %s" % (show(cur["description"]), show(lab["description"])))
        if changes:
            edits += 1
            commands.append(("edit    %s  %s" % (show(cur["name"]), "; ".join(changes)),
                             ["api", "--method", "PATCH", base + "/" + quote(cur["name"], safe=""),
                              "-f", "new_name=" + lab["name"]] + fields))
    wanted = set(lab["name"].lower() for lab in labels)
    for c in current:
        if c["name"].lower() in wanted:
            continue
        if prune:
            deletes += 1
            commands.append(("delete  %s  (not in the label file)" % show(c["name"]),
                             ["api", "--method", "DELETE", base + "/" + quote(c["name"], safe="")]))
        else:
            extras.append(c["name"])
    for human, _ in commands:
        print("  " + human)
    for name in extras:
        print("  keep    %s  (not in the label file; --prune deletes it)" % show(name))
    summary = "%s: %d to create, %d to edit, %d to delete" % (repo, creates, edits, deletes)
    if extras:
        summary += ", %d not in the file kept" % len(extras)
    print(summary)
    # Each command: its description, then gh's arguments, then an empty field; all NUL-terminated.
    with open(commands_path, "wb") as f:
        for human, argv in commands:
            for field in [human] + argv:
                f.write(field.encode("utf-8") + b"\0")
            f.write(b"\0")


def main():
    mode, path = sys.argv[1], sys.argv[2]
    labels = parse(path)
    if mode == "print":
        print(json.dumps(labels, ensure_ascii=False, indent=2))
    else:
        current, repo, prune, limit, commands = sys.argv[3:8]
        plan(labels, current, repo, prune == "1", int(limit), commands)


main()
PY

if [ "$print" -eq 1 ]; then
    exec python3 -I -c "$PLANNER" print "$file"
fi

command -v gh >/dev/null 2>&1 || die "gh is required (https://cli.github.com), logged in with gh auth login"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/sync-labels.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Validate the file before asking GitHub anything.
python3 -I -c "$PLANNER" print "$file" >/dev/null
if ! gh label list --repo "$repo" --json name,color,description --limit "$limit" > "$tmp/current.json" 2> "$tmp/err"; then
    sed 's/^/  /' "$tmp/err" >&2
    die "could not list the labels of $repo (gh auth status; does the repository exist?)"
fi
python3 -I -c "$PLANNER" plan "$file" "$tmp/current.json" "$repo" "$prune" "$limit" "$tmp/commands"

planned=0 applied=0 failed=0 human=""
args=()
while IFS= read -r -d '' field; do
    if [ -z "$human" ]; then human="$field"; continue; fi
    if [ -n "$field" ]; then args+=("$field"); continue; fi
    planned=$((planned + 1))
    if [ "$dry_run" -eq 0 ]; then
        if gh "${args[@]}" > /dev/null 2> "$tmp/err"; then
            applied=$((applied + 1))
        else
            failed=$((failed + 1))
            printf 'sync-labels: failed: %s\n' "$human" >&2
            sed 's/^/  /' "$tmp/err" >&2
        fi
    fi
    human=""
    args=()
done < "$tmp/commands"

if [ "$planned" -eq 0 ]; then
    echo "In sync: nothing to change."
elif [ "$dry_run" -eq 1 ]; then
    echo "Dry run: $planned change(s) planned, none made."
elif [ "$failed" -gt 0 ]; then
    echo "Made $applied of $planned change(s); $failed failed (rerun to retry them)."
    exit 1
else
    echo "Done: $applied change(s)."
fi
