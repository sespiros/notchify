#!/bin/sh
# Integration test for notchify-recipes. Builds the binary, then
# exercises list / install / re-install (idempotency) / uninstall
# against a temp prefix. Verifies that:
#   - codex install lays down the expected file tree
#   - claude install merges into an existing settings.json without
#     clobbering unrelated entries (simulated "herd" hook)
#   - re-running install does not duplicate our hook entries
#   - uninstall removes our entries and our files but leaves
#     unrelated entries and unrelated keys intact
#
# Run from repo root: scripts/test-recipes.sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

command -v jq >/dev/null || { echo "test needs jq"; exit 1; }

echo "==> building notchify-recipes"
swift build --product notchify-recipes >/dev/null
BIN="$ROOT/.build/debug/notchify-recipes"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

echo "==> list"
out=$("$BIN" list)
echo "$out" | grep -q '^claude-code' || fail "list missing claude-code"
echo "$out" | grep -q '^codex' || fail "list missing codex"
pass "list shows both recipes"

echo "==> codex install merges into existing hooks.json"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Pre-seed hooks.json with a chezmoi-style statusline registration to
# prove the recipe doesn't clobber it.
mkdir -p "$TMP/.codex"
cat > "$TMP/.codex/hooks.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      { "hooks": [{ "type": "command", "command": "sh ~/.codex/hooks/tmux-statusline-state.sh working" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "sh ~/.codex/hooks/tmux-statusline-state.sh idle" }] }
    ]
  }
}
JSON
"$BIN" install codex --prefix "$TMP" >/dev/null
[ -x "$TMP/.codex/hooks/notchify-agent-state.sh" ] || fail "hook script not executable"
[ -f "$TMP/.config/codex/icons/done.png" ] || fail "icon not installed"
[ -f "$TMP/.config/notchify/installed/codex" ] || fail "install marker missing"
statusline_count=$(jq '[.. | objects | select(.command? // "" | contains("tmux-statusline-state.sh"))] | length' "$TMP/.codex/hooks.json")
notchify_count=$(jq '[.. | objects | select(.command? // "" | contains("notchify-agent-state.sh"))] | length' "$TMP/.codex/hooks.json")
[ "$statusline_count" = 2 ] || fail "statusline entries lost (count=$statusline_count)"
[ "$notchify_count" = 2 ] || fail "notchify entries missing (count=$notchify_count, expected Stop+PermissionRequest)"
pass "codex co-existence with chezmoi-style statusline registration"

echo "==> claude install merging into existing settings.json"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.claude"
cat > "$TMP/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "Stop": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "/usr/local/bin/herd-hook" }] }]
  },
  "model": "claude-opus-4-7"
}
JSON
"$BIN" install claude-code --prefix "$TMP" >/dev/null
herd_count=$(jq '[.hooks.Stop[] | select(.hooks[0].command == "/usr/local/bin/herd-hook")] | length' "$TMP/.claude/settings.json")
ours_count=$(jq '[.hooks.Stop[] | select(.hooks[0].command | contains("notchify-agent-state.sh"))] | length' "$TMP/.claude/settings.json")
[ "$herd_count" = 1 ] || fail "herd hook lost (count=$herd_count)"
[ "$ours_count" = 1 ] || fail "our hook missing (count=$ours_count)"
[ "$(jq -r '.model' "$TMP/.claude/settings.json")" = "claude-opus-4-7" ] || fail "model key lost"
pass "co-existence with unrelated hook + unrelated keys"

echo "==> idempotency: install twice"
"$BIN" install claude-code --prefix "$TMP" >/dev/null
ours_after=$(jq '[.hooks.Stop[] | select(.hooks[0].command | contains("notchify-agent-state.sh"))] | length' "$TMP/.claude/settings.json")
[ "$ours_after" = 1 ] || fail "double-install duplicated entries (count=$ours_after)"
pass "second install does not duplicate"

echo "==> uninstall preserves unrelated entries"
"$BIN" uninstall claude-code --prefix "$TMP" >/dev/null
herd_after=$(jq '[.hooks.Stop[] | select(.hooks[0].command == "/usr/local/bin/herd-hook")] | length' "$TMP/.claude/settings.json")
ours_after=$(jq '[.. | objects | select(.command? // "" | contains("notchify-agent-state.sh"))] | length' "$TMP/.claude/settings.json")
[ "$herd_after" = 1 ] || fail "uninstall dropped herd hook"
[ "$ours_after" = 0 ] || fail "uninstall left our entries (count=$ours_after)"
[ -e "$TMP/.claude/hooks/notchify-agent-state.sh" ] && fail "hook script not removed" || true
[ -e "$TMP/.config/notchify/installed/claude-code" ] && fail "install marker not removed" || true
pass "uninstall is surgical"

echo "==> status detects drift after registration is rewritten"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
"$BIN" install codex --prefix "$TMP" >/dev/null
NOTCHIFY_PREFIX="$TMP" "$BIN" status >/dev/null 2>&1 || fail "status reported drift on a fresh install"
# Simulate chezmoi rewriting hooks.json with statusline-only entries:
cat > "$TMP/.codex/hooks.json" <<'JSON'
{
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command": "sh ~/.codex/hooks/tmux-statusline-state.sh idle" }] }]
  }
}
JSON
out=$(NOTCHIFY_PREFIX="$TMP" "$BIN" status 2>&1) && fail "status did not return nonzero on drift" || true
echo "$out" | grep -q "registrations missing" || fail "status missing drift message: $out"
pass "drift detected after external rewrite"

echo "==> hook scripts stay non-fatal if notchify itself fails"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/notchify" <<'SH'
#!/bin/sh
exit 1
SH
chmod 755 "$TMP/bin/notchify"

"$BIN" install codex --prefix "$TMP" >/dev/null
HOME="$TMP" PATH="$TMP/bin:$PATH" sh "$TMP/.codex/hooks/notchify-agent-state.sh" idle ||
  fail "codex hook propagated notchify failure"

"$BIN" install claude-code --prefix "$TMP" >/dev/null
HOME="$TMP" PATH="$TMP/bin:$PATH" sh "$TMP/.claude/hooks/notchify-agent-state.sh" idle ||
  fail "claude hook propagated notchify failure"

pass "hook scripts do not fail the agent when notchify is unavailable"

echo "==> codex stop hook treats assistant handoff as blocked"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/notchify" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP/notchify.log"
SH
chmod 755 "$TMP/bin/notchify"
"$BIN" install codex --prefix "$TMP" >/dev/null
payload='{"hook_event_name":"Stop","last_assistant_message":"Your manual steps: create the user. Once you confirm 1-4 done and paste me the UID, I will continue."}'
printf %s "$payload" | HOME="$TMP" PATH="$TMP/bin:$PATH" TMPDIR="$TMP" sh "$TMP/.codex/hooks/notchify-agent-state.sh" idle ||
  fail "codex stop hook failed while classifying input request"
grep -q 'blocked.png' "$TMP/notchify.log" || fail "input-request stop did not use blocked notification"
grep -q 'waiting for input' "$TMP/notchify.log" || fail "input-request stop missing waiting body"
pass "assistant handoff becomes blocked notification"

echo "==> codex stop hook leaves completion summaries idle"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/notchify" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP/notchify.log"
SH
chmod 755 "$TMP/bin/notchify"
"$BIN" install codex --prefix "$TMP" >/dev/null
payload='{"hook_event_name":"Stop","last_assistant_message":"What changed: Claude finished the cleanup and all tests passed."}'
printf %s "$payload" | HOME="$TMP" PATH="$TMP/bin:$PATH" TMPDIR="$TMP" sh "$TMP/.codex/hooks/notchify-agent-state.sh" idle ||
  fail "codex stop hook failed on completion summary"
grep -q 'done' "$TMP/notchify.log" || fail "completion summary did not produce done notification"
! grep -q 'blocked.png' "$TMP/notchify.log" || fail "completion summary was misclassified as blocked"
pass "completion summary remains done notification"

echo "==> codex permission hook notifies on approval wait"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/notchify" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP/notchify.log"
SH
chmod 755 "$TMP/bin/notchify"
"$BIN" install codex --prefix "$TMP" >/dev/null
payload='{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"git commit -m fix"}}'
printf %s "$payload" | HOME="$TMP" PATH="$TMP/bin:$PATH" TMPDIR="$TMP" sh "$TMP/.codex/hooks/notchify-agent-state.sh" blocked ||
  fail "codex permission hook failed"
grep -q 'blocked.png' "$TMP/notchify.log" || fail "permission hook did not use blocked notification"
grep -q 'git commit -m fix' "$TMP/notchify.log" || fail "permission hook missing command body"
pass "permission request becomes blocked notification"

if command -v shellcheck >/dev/null 2>&1; then
    echo "==> shellcheck"
    shellcheck recipes/lib/install-common.sh \
               recipes/claude-code/install.sh recipes/claude-code/uninstall.sh \
               recipes/codex/install.sh recipes/codex/uninstall.sh \
               || fail "shellcheck reported issues"
    pass "shellcheck clean"
else
    echo "  (skipping shellcheck; not installed)"
fi

echo "all tests passed"
