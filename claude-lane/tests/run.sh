#!/bin/bash
# tests/run.sh - exercise claude_lane.sh / claude_lane.zsh / install.sh against a throwaway HOME
# with a fake Keychain (`security`), fake `code`, `claude` and `open`. Touches nothing real.
# usage: bash tests/run.sh        (needs bash, jq, shasum; zsh for the zsh cases)
set -uo pipefail

kit=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/claude-lane-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
stub="$work/stub"; mkdir -p "$stub"
pass=0 fail=0
command -v jq >/dev/null 2>&1 || { echo "jq is required (brew install jq)"; exit 1; }
# Every case runs under env -i. Keep jq reachable: Homebrew puts it outside /usr/bin:/bin.
P="$stub:$(dirname "$(command -v jq)"):/usr/bin:/bin"

# ---------------------------------------------------------------- stubs
cat > "$stub/security" <<'EOF'
#!/bin/bash
# Fake Keychain: one file per service name under $FAKE_KEYCHAIN.
cmd="$1"; shift; s=""
while [ $# -gt 0 ]; do [ "$1" = -s ] && s="$2"; shift; done
case "$cmd" in
  find-generic-password)   [ -n "$s" ] && [ -f "$FAKE_KEYCHAIN/$s" ] ;;
  add-generic-password)    : > "$FAKE_KEYCHAIN/$s" ;;
  delete-generic-password) rm "$FAKE_KEYCHAIN/$s" ;;
  dump-keychain) for f in "$FAKE_KEYCHAIN"/*; do [ -e "$f" ] && printf '    0x00000007 <blob>="x"\n    "svce"<blob>="%s"\n' "${f##*/}"; done; exit 0 ;;
esac
EOF
cat > "$stub/code" <<'EOF'
#!/bin/bash
{ printf 'ARGS:'; printf ' [%s]' ${1+"$@"}; printf '\n'; env | sort; } > "$FAKE_CODE_LOG"
EOF
cat > "$stub/claude" <<'EOF'
#!/bin/bash
printf '%s\n' "{\"type\":\"system\",\"subtype\":\"init\",\"model\":\"haiku-stub\",\"claude_code_version\":\"0.0.0\",\"mcp_servers\":[]}"
d="${CLAUDE_CONFIG_DIR:-unset}"
printf '%s\n' "{\"type\":\"result\",\"result\":\"OK dir=${d##*/}\",\"total_cost_usd\":0,\"is_error\":false}"
EOF
printf '#!/bin/bash\necho "open $*" > "$FAKE_CODE_LOG"\n' > "$stub/open"
chmod +x "$stub"/*

# ---------------------------------------------------------------- fixtures
H=""
svc() { if [ -z "${1:-}" ]; then printf 'Claude Code-credentials'; else printf 'Claude Code-credentials-%s' "$(printf '%s' "$1" | shasum -a 256 | cut -c1-8)"; fi; }
acct() { printf '{"emailAddress":"%s","accountUuid":"%s","organizationUuid":"%s","organizationName":"%s","organizationRole":"admin"}' "$1" "$2" "$3" "$4"; }

new_home() {  # fresh HOME: lane A populated and signed in as $1 (default a@example.com)
  H="$work/home$RANDOM$RANDOM"; mkdir -p "$H/.claude/scripts" "$H/keychain"
  local A="$H/.claude" d
  for d in projects sessions rules skills agents hooks plugins backups session-env .git; do mkdir -p "$A/$d"; done
  mkdir -p "$A/projects/-Users-x-repo"
  echo '{"model":"opus","syncClaudeAiSkills":false}' > "$A/settings.json"
  cat > "$A/settings.local.json" <<'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"deny.sh"}]}],
 "PostToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"scan.sh"}]}],
 "UserPromptSubmit":[{"hooks":[{"type":"command","command":"p.sh"}]}],
 "Stop":[{"hooks":[{"type":"command","command":"s.sh"}]}]}}
EOF
  echo '{}' > "$A/policy-limits.json"; echo '{}' > "$A/remote-settings.json"
  echo '{"secret":1}' > "$A/.credentials.json"; echo '{"leftover":1}' > "$A/.claude.json"
  login_a "${1:-a@example.com}" acc-a org-a "A's Organization"
}
login_a() {
  jq -n --argjson o "$(acct "$1" "$2" "$3" "$4")" '{oauthAccount:$o, primaryApiKey:"sk-should-not-copy",
      cachedUsageUtilization:{utilization:{five_hour:{utilization:12},seven_day:{utilization:34}},fetchedAtMs:1758000000000},
      someOtherCache:{x:1}, userID:"u1",
      mcpServers:{alpha:{command:"a"},beta:{command:"b"}},
      projects:{"/p/trusted":{hasTrustDialogAccepted:true},"/p/untrusted":{hasTrustDialogAccepted:false}}}' > "$H/.claude.json"
  : > "$H/keychain/$(svc "")"
}
login_b() {  # what the CLI does on first sign-in in lane B
  local f="$H/.claude-b/.claude.json"
  jq --argjson o "$(acct "$1" "$2" "$3" "$4")" '.oauthAccount = $o' "$f" > "$f.t" && mv "$f.t" "$f"
  : > "$H/keychain/$(svc "$H/.claude-b")"
}
bind() { printf 'CLAUDE_LANE_A_EMAIL=%s\nCLAUDE_LANE_B_EMAIL="%s"\n' "$1" "$2" > "$H/.claude/scripts/claude_lane.conf"; }

lane() {  # run claude_lane.sh inside the fake HOME with a clean environment; extra VAR=val first
  local envs=()
  while [ $# -gt 0 ] && [[ "$1" == *=* ]]; do envs+=("$1"); shift; done
  env -i HOME="$H" PATH="$P" FAKE_KEYCHAIN="$H/keychain" FAKE_CODE_LOG="$H/code.log" \
    ${envs[@]+"${envs[@]}"} bash "$kit/claude_lane.sh" ${1+"$@"} > "$H/out" 2>&1
}

# ---------------------------------------------------------------- assertions
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; sed 's/^/        | /' "$H/out" 2>/dev/null | head -40; }
expect_rc()   { if [ "$2" = "$3" ]; then ok "$1 (exit $3)"; else bad "$1: expected exit $2, got $3"; fi; }
expect_out()  { if grep -q -- "$2" "$H/out"; then ok "$1"; else bad "$1: output lacks /$2/"; fi; }
expect_nout() { if grep -q -- "$2" "$H/out"; then bad "$1: output has /$2/"; else ok "$1"; fi; }
check()       { if eval "$2"; then ok "$1"; else bad "$1: [$2] is false"; fi; }

echo "== derivation"
check "keychain hash matches the value measured on the old Mac (ac37998e)" \
  '[ "$(svc /Users/takafumi.obata/.claude-team)" = "Claude Code-credentials-ac37998e" ]'
H="$work"; bash -c "source <(sed -n '/^keychain_service()/,/^}/p' '$kit/claude_lane.sh'); keychain_service /Users/takafumi.obata/.claude-team" > "$work/out"
check "claude_lane.sh derives the same name" 'grep -q "Claude Code-credentials-ac37998e" "$work/out"'

echo "== shells / usage"
new_home
if command -v zsh >/dev/null 2>&1; then
  env -i HOME="$H" PATH="$P" zsh "$kit/claude_lane.sh" status > "$H/out" 2>&1; expect_rc "zsh launch refused" 1 $?
fi
lane; rc=$?; expect_rc "no command prints usage" 1 $rc
expect_out "usage starts at the header" "claude_lane.sh v3"
expect_out "usage ends with the #92252 line" "#92252"
expect_nout "usage does not leak code" "BASH_VERSION"
lane CLAUDE_LANE_B_DIR="$H/.claude" status; expect_rc "lane B dir == ~/.claude refused" 1 $?

echo "== setup"
new_home; rm "$H/.claude.json"; lane setup; expect_rc "setup before lane A login" 1 $?
new_home; lane CLAUDE_CONFIG_DIR="$H/.claude" setup; expect_rc "setup with CLAUDE_CONFIG_DIR=~/.claude" 1 $?
expect_out "  names #92252" "92252"
new_home b@example.com; bind a@example.com b@example.com; lane setup; expect_rc "setup when lane A holds the lane-B login" 1 $?
expect_out "  says which login lane A must be" "bound to a@example.com"
check "  lane B not created" '[ ! -e "$H/.claude-b" ]'
new_home A@Example.com; bind a@example.com b@example.com; lane setup; expect_rc "binding compare ignores case" 0 $?

new_home; bind a@example.com b@example.com; lane setup; expect_rc "setup happy path" 0 $?
expect_out "  links created, none unlinked" "unlinked_real=0"
expect_out "  next step names the lane-B login" "b@example.com"
B="$H/.claude-b"
check "  projects is a symlink into lane A" '[ "$(readlink "$B/projects")" = "$H/.claude/projects" ]'
check "  settings.local.json is a symlink" '[ -L "$B/settings.local.json" ]'
check "  scripts (with the binding) is shared" '[ -L "$B/scripts" ]'
for n in .git .credentials.json policy-limits.json remote-settings.json; do
  check "  $n NOT linked" '[ ! -e "$B/'"$n"'" ]'
done
check "  .claude.json is a real file, mode 600" '[ -f "$B/.claude.json" ] && [ ! -L "$B/.claude.json" ] && [ "$(stat -c %a "$B/.claude.json" 2>/dev/null || stat -f %Lp "$B/.claude.json")" = 600 ]'
check "  seeded from ~/.claude.json, not ~/.claude/.claude.json" 'jq -e ".mcpServers.alpha" "$B/.claude.json" >/dev/null'
check "  oauthAccount stripped" '[ "$(jq -r ".oauthAccount // \"gone\"" "$B/.claude.json")" = gone ]'
check "  primaryApiKey stripped" '[ "$(jq -r ".primaryApiKey // \"gone\"" "$B/.claude.json")" = gone ]'
check "  *cache* keys stripped" '[ "$(jq "[keys[] | select(test(\"cache\";\"i\"))] | length" "$B/.claude.json")" = 0 ]'
lane setup; expect_rc "setup is re-runnable" 0 $?
expect_out "  second run creates nothing" "links: created=0"

new_home; mkdir -p "$H/.claude-b/projects"; lane setup; expect_rc "setup when lane B was launched first (real projects/)" 1 $?
new_home; : > "$H/keychain/$(svc "$H/.claude-b")"; lane setup; expect_rc "setup with a stale lane-B credential" 0 $?
expect_out "  warns about the stale credential" "delete-generic-password"

echo "== verify"
new_home; bind a@example.com b@example.com; lane setup >/dev/null
lane verify; expect_rc "lane B not logged in yet" 1 $?
expect_out "  says so" "lane B is not logged in"
login_b b@example.com acc-b org-b "B's Organization"
lane verify; expect_rc "Max + Max, each lane on its bound login" 0 $?
expect_out "  PASS line" "PASS: two lanes"
expect_nout "  no NOTE about the binding" "no account binding"

new_home; bind a@example.com b@example.com; lane setup >/dev/null; login_b c@example.com acc-c org-c "C's Organization"
lane verify; expect_rc "lane B signed into a third account" 1 $?
expect_out "  names the expected login" "lane B must be signed into b@example.com"

new_home b@example.com; lane setup >/dev/null; login_b a@example.com acc-a2 org-a2 "A's Organization"
bind a@example.com b@example.com; lane verify; expect_rc "lanes swapped" 1 $?
expect_out "  says SWAPPED" "SWAPPED"

new_home; lane setup >/dev/null; login_b a@example.com acc-a org-a2 "Team Org"
lane verify; expect_rc "same account, second org (the old Mac's shape)" 1 $?
expect_out "  same login detected" "SAME login"
lane CLAUDE_LANE_ALLOW_SAME_ACCOUNT=1 verify; expect_rc "  ... accepted with ALLOW_SAME_ACCOUNT and no binding" 0 $?
expect_out "  with a NOTE" "NOT Max + Max"

new_home; lane setup >/dev/null; login_b b@example.com acc-b org-a "A's Organization"
lane verify; expect_rc "same organization" 1 $?

new_home; lane setup >/dev/null; login_b b@example.com acc-b org-b "B's Organization"
lane verify; expect_rc "no binding configured" 0 $?
expect_out "  NOTE about the missing binding" "no account binding"
lane CLAUDE_CODE_OAUTH_TOKEN=x verify; expect_rc "CLAUDE_CODE_OAUTH_TOKEN in the shell" 1 $?
lane ANTHROPIC_API_KEY=x verify; expect_rc "ANTHROPIC_API_KEY in the shell (NOTE only)" 0 $?
expect_out "  NOTE printed" "ANTHROPIC_API_KEY"
: > "$H/keychain/$(svc "$H/.claude-typo")"
lane verify; expect_rc "a third Keychain identity (NOTE only)" 0 $?
expect_out "  NOTE printed" "3 'Claude Code-credentials"
mv "$H/.claude/settings.local.json" "$H/settings.local.json.away"
lane verify; expect_rc "settings.local.json missing" 1 $?
echo '{"hooks":{}}' > "$H/.claude/settings.local.json"
lane verify; expect_rc "settings.local.json with 0 hooks" 1 $?
mv "$H/settings.local.json.away" "$H/.claude/settings.local.json"
# The old Mac's real shape: every hook in settings.json, running scripts from ~/claude-code-config.
mkdir -p "$H/claude-code-config/hooks"; touch "$H/claude-code-config/hooks/"{pre,post,prompt,stop}.sh
jq -n '{model:"opus", hooks:{
  PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:"bash ~/claude-code-config/hooks/pre.sh"}]}],
  PostToolUse:[{matcher:"*",hooks:[{type:"command",command:"bash ~/claude-code-config/hooks/post.sh"}]}],
  UserPromptSubmit:[{hooks:[{type:"command",command:"\"$HOME/claude-code-config/hooks/prompt.sh\""}]}],
  Stop:[{hooks:[{type:"command",command:"${HOME}/claude-code-config/hooks/stop.sh --quiet"}]}]}}' > "$H/.claude/settings.json"
echo '{"permissions":{"allow":[]}}' > "$H/.claude/settings.local.json"
lane verify; expect_rc "hooks wired only in settings.json (settings.local.json has none)" 0 $?
expect_out "  shows where the hooks are" "hooks  : settings.json=4 settings.local.json=0"
rm "$H/claude-code-config/hooks/pre.sh"
lane verify; expect_rc "a hook's script is missing" 1 $?
expect_out "  names the missing script" "hook script is missing: $H/claude-code-config/hooks/pre.sh"
touch "$H/claude-code-config/hooks/pre.sh"
jq 'del(.hooks.Stop)' "$H/.claude/settings.json" > "$H/t" && mv "$H/t" "$H/.claude/settings.json"
lane verify; expect_rc "one event wired nowhere" 1 $?
expect_out "  names the event" "hook event Stop is wired in neither"
jq -n '{hooks:{Stop:[{hooks:[{type:"command",command:"bash ~/claude-code-config/hooks/stop.sh"}]}]}}' > "$H/.claude/settings.local.json"
lane verify; expect_rc "events split across settings.json and settings.local.json" 0 $?
rm -rf "$H/.claude/skills"; lane verify; expect_rc "dangling critical symlink" 1 $?
expect_out "  names it" "DANGLING"
mkdir "$H/.claude/skills"; rm "$H/.claude-b/rules"; mkdir "$H/.claude-b/rules"
lane verify; expect_rc "critical entry is a real dir in lane B" 1 $?

echo "== sync / status / doctor"
new_home; lane setup >/dev/null
jq '.mcpServers = {onlyB:{command:"x"}}' "$H/.claude-b/.claude.json" > "$H/t" && mv "$H/t" "$H/.claude-b/.claude.json"
touch "$H/.claude/new-in-a"
lane sync; expect_rc "sync" 0 $?
check "  new lane-A entry linked" '[ -L "$H/.claude-b/new-in-a" ]'
check "  mcpServers ASSIGNED from lane A" '[ "$(jq -c ".mcpServers | keys" "$H/.claude-b/.claude.json")" = "[\"alpha\",\"beta\"]" ]'
check "  trust flag carried" 'jq -e ".projects[\"/p/trusted\"].hasTrustDialogAccepted == true" "$H/.claude-b/.claude.json" >/dev/null'
check "  untrusted not flipped to trusted" 'jq -e ".projects[\"/p/untrusted\"].hasTrustDialogAccepted != true" "$H/.claude-b/.claude.json" >/dev/null'
login_b b@example.com acc-b org-b "B's Organization"; bind a@example.com b@example.com
lane status; expect_rc "status" 0 $?
expect_out "  shows lane A binding" "bound to : a@example.com"
expect_out "  shows cached usage" "5h=12%"
expect_out "  lists keychain entries" "Claude Code-credentials-"
lane doctor; expect_rc "doctor (stub claude)" 0 $?
expect_out "  lane A probed with CLAUDE_CONFIG_DIR unset" "OK dir=unset"
expect_out "  lane B probed with its dir" "OK dir=.claude-b"

echo "== vscode"
new_home; bind a@example.com b@example.com
lane CLAUDECODE=1 CLAUDE_CODE_ENTRYPOINT=cli ANTHROPIC_MODEL=x vscode /some/folder; expect_rc "vscode (sets up lane B on the way)" 0 $?
L="$H/code.log"
check "  args: new window, own profile, shared extensions, folder" 'grep -q "^ARGS: \[--new-window\] \[--user-data-dir\] \[$H/.vscode-b\] \[--extensions-dir\] \[$H/.vscode/extensions\] \[/some/folder\]" "$L"'
check "  CLAUDE_CONFIG_DIR is lane B" 'grep -qx "CLAUDE_CONFIG_DIR=$H/.claude-b" "$L"'
check "  CLAUDE_LANE=b" 'grep -qx "CLAUDE_LANE=b" "$L"'
check "  CLAUDECODE / CLAUDE_CODE_* / ANTHROPIC_* scrubbed" '! grep -qE "^(CLAUDECODE|CLAUDE_CODE_ENTRYPOINT|ANTHROPIC_MODEL)=" "$L"'
S="$H/.vscode-b/User/settings.json"
check "  no main profile: markers-only settings are valid JSON" 'jq -e ".\"window.title\" | startswith(\"[MAX-B]\")" "$S" >/dev/null'
check "  blue title bar" '[ "$(grep -c 1f4e79 "$S")" -ge 3 ]'
new_home; mkdir -p "$H/Library/Application Support/Code/User"
printf '{\n  "editor.fontSize": 13,\n  "files.autoSave": "afterDelay"\n}\n' > "$H/Library/Application Support/Code/User/settings.json"
lane vscode; S="$H/.vscode-b/User/settings.json"
check "main profile starting with '{': merged, valid JSON" 'jq -e ".\"editor.fontSize\" == 13 and (.\"window.title\" | startswith(\"[MAX-B]\"))" "$S" >/dev/null'
new_home; mkdir -p "$H/Library/Application Support/Code/User"
printf '// my settings\n{ "editor.fontSize": 13 }\n' > "$H/Library/Application Support/Code/User/settings.json"
lane vscode; S="$H/.vscode-b/User/settings.json"
check "main profile starting with a comment: merge skipped, still valid" 'jq -e "has(\"editor.fontSize\") | not" "$S" >/dev/null'
expect_out "  and warned" "merge skipped"
new_home; lane vscode; expect_rc "vscode from an environment with no CLAUDE*/ANTHROPIC* vars (empty-array case)" 0 $?
check "  no folder argument: nothing extra passed to code" 'grep -q "^ARGS: \[--new-window\] \[--user-data-dir\] \[$H/.vscode-b\] \[--extensions-dir\] \[$H/.vscode/extensions\]$" "$H/code.log"'
new_home; lane CLAUDE_LANE_B_TAG=WORK CLAUDE_LANE_B_COLOR="#7a3b1f" vscode
check "tag / colour overrides" 'grep -q "\[WORK\]" "$H/.vscode-b/User/settings.json" && grep -q 7a3b1f "$H/.vscode-b/User/settings.json"'
new_home; lane desktop; check "desktop opens a second instance" 'grep -q "open -n -a Claude --args --user-data-dir=$H/Library/Application Support/Claude-b" "$H/code.log"'

echo "== claude_lane.zsh"
if command -v zsh >/dev/null 2>&1; then
  new_home
  zsh -n "$kit/claude_lane.zsh"; expect_rc "zsh -n" 0 $?
  z() { env -i HOME="$H" PATH="$P" "$@" zsh -f -c 'PROMPT="%# "; source "'"$kit"'/claude_lane.zsh"; print -r -- "lane=$CLAUDE_LANE dir=${CLAUDE_CONFIG_DIR:-unset} prompt=$PROMPT"; whence -w ccb cca; alias code-b code-team' > "$H/out" 2>&1; }
  z; expect_out "plain shell is lane A" "lane=a dir=unset"
  expect_out "  ccb / cca defined" "ccb: function"
  expect_out "  code-team is the same command as code-b" "code-team=.*claude_lane.sh vscode"
  z CLAUDE_CONFIG_DIR="$H/.claude"; expect_out "CLAUDE_CONFIG_DIR=~/.claude is unset (#92252 guard)" "lane=a dir=unset"
  z CLAUDE_CONFIG_DIR="$H/.claude-b"; expect_out "lane-B shell gets the prompt marker" "lane=b dir=$H/.claude-b prompt=%F{blue}\[MAX-B\]%f"
  env -i HOME="$H" PATH="$P" CLAUDECODE=1 zsh -f -c 'source "'"$kit"'/claude_lane.zsh"; ccb' > "$H/out" 2>&1
  expect_out "ccb runs claude in lane B" "OK dir=.claude-b"
  env -i HOME="$H" PATH="$P" CLAUDE_CONFIG_DIR="$H/.claude-b" zsh -f -c 'source "'"$kit"'/claude_lane.zsh"; cca' > "$H/out" 2>&1
  expect_out "cca runs claude in lane A even from a lane-B shell" "OK dir=unset"
fi

echo "== install.sh"
inst() { env -i HOME="$H" PATH="$P" bash "$kit/install.sh" ${1+"$@"} > "$H/out" 2>&1; }
H="$work/fresh$RANDOM"; mkdir -p "$H"
inst --lane-a a@example.com --lane-b b@example.com; expect_rc "refuses before ~/.claude exists" 1 $?
check "  and does not create ~/.claude" '[ ! -e "$H/.claude" ]'
new_home; rm -rf "$H/.claude/scripts"
inst; expect_rc "refuses with no binding at all" 1 $?
inst --lane-a a@example.com --lane-b A@example.com; expect_rc "refuses the same login twice" 1 $?
inst --lane-a a@example.com --lane-b 'b @example.com'; expect_rc "refuses a malformed address" 1 $?
inst --lane-a a@example.com --lane-b b@example.com; expect_rc "installs" 0 $?
expect_out "  parse + v3 checks pass" "OK: v3 with account binding"
check "  scripts copied, executable" '[ -x "$H/.claude/scripts/claude_lane.sh" ] && cmp -s "$kit/claude_lane.zsh" "$H/.claude/scripts/claude_lane.zsh"'
check "  binding file is 600" '[ "$(stat -c %a "$H/.claude/scripts/claude_lane.conf" 2>/dev/null || stat -f %Lp "$H/.claude/scripts/claude_lane.conf")" = 600 ]'
check "  zshrc source line added once" '[ "$(grep -c claude_lane.zsh "$H/.zshrc")" = 1 ]'
inst; expect_rc "re-install keeps the binding" 0 $?
check "  zshrc line still once" '[ "$(grep -c claude_lane.zsh "$H/.zshrc")" = 1 ]'
check "  binding intact" 'grep -qx "CLAUDE_LANE_B_EMAIL=b@example.com" "$H/.claude/scripts/claude_lane.conf"'
echo "old v1" > "$H/.claude/scripts/claude_lane.sh"
inst --lane-a a@example.com --lane-b c@example.com; expect_rc "re-bind" 0 $?
check "  old script and old binding backed up" 'ls "$H"/.claude-lane-backups/*/claude_lane.sh "$H"/.claude-lane-backups/*/claude_lane.conf >/dev/null 2>&1'
lane setup >/dev/null; login_b c@example.com acc-c org-c "C's Organization"
env -i HOME="$H" PATH="$P" FAKE_KEYCHAIN="$H/keychain" bash "$H/.claude/scripts/claude_lane.sh" verify > "$H/out" 2>&1
expect_rc "installed copy reads the binding and passes verify" 0 $?

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
