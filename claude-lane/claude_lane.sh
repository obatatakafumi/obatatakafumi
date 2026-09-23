#!/bin/bash
# claude_lane.sh v3 - two Claude Code subscriptions side by side on one Mac, one shared config.
#
#   Lane A = ~/.claude           plain `claude` / the regular VS Code   (CLAUDE_CONFIG_DIR unset)
#   Lane B = $CLAUDE_LANE_B_DIR  `ccb` / `code-b` (its own VS Code)     (default ~/.claude-b)
#
# usage: claude_lane.sh <command>
#   setup     create lane B: symlink lane A's shared entries, seed lane B's own .claude.json
#   sync      link entries new in lane A, copy mcpServers + project trust flags A -> B
#   status    identity / keychain / cached usage of both lanes
#   verify    acceptance test, no API call. exit 0 = two lanes, two subscriptions, shared config
#   doctor    API probe of both lanes  [--full: configured model] [--with-mcp: load MCP servers]
#   vscode    open a lane-B VS Code window (own profile, [TAG] title, coloured title bar)
#   desktop   open a second Claude Desktop instance
#
# Account binding (fail-closed in setup and verify when set). Taken from the environment, else
# from $CLAUDE_LANE_CONF (default ~/.claude/scripts/claude_lane.conf), plain KEY=value lines:
#   CLAUDE_LANE_A_EMAIL   the login lane A must be signed into
#   CLAUDE_LANE_B_EMAIL   the login lane B must be signed into
#
# Other overrides: CLAUDE_LANE_B_DIR (~/.claude-b)  CLAUDE_LANE_B_TAG (MAX-B)
#   CLAUDE_LANE_B_COLOR (#1f4e79)  CLAUDE_LANE_ALLOW_SAME_ACCOUNT=1 (one account, two orgs)
#
# Run with bash (macOS /bin/bash 3.2 is fine), never zsh: link_entries relies on unmatched globs
# passing through, which zsh's default `nomatch` turns into a fatal error.
# Never export CLAUDE_CONFIG_DIR=~/.claude: it hashes to a different Keychain entry (#92252).

if [ -z "${BASH_VERSION:-}" ]; then
  echo "claude_lane.sh: run it with bash (bash $0 ...), not zsh or sh." >&2
  exit 1
fi
# No `set -e`: probe_lane reads the exit code of a failing command substitution on purpose.
set -uo pipefail

LANE_A="$HOME/.claude"
LANE_B="${CLAUDE_LANE_B_DIR:-$HOME/.claude-b}"
LANE_B_TAG="${CLAUDE_LANE_B_TAG:-MAX-B}"
LANE_B_COLOR="${CLAUDE_LANE_B_COLOR:-#1f4e79}"
VSCODE_DATA_B="$HOME/.vscode-b"
DESKTOP_DATA_B="$HOME/Library/Application Support/Claude-b"
CLAUDE_LANE_CONF="${CLAUDE_LANE_CONF:-$LANE_A/scripts/claude_lane.conf}"

# Entries of lane A that must NOT become symlinks in lane B:
#   .claude.json / .credentials.json   the lane's identity and credential -- the whole point of a lane
#   .git                               lane A's repo metadata; ~/.claude-b must not look like that repo
#   policy-limits.json(.stamp.json) remote-settings.json   per-lane runtime state the CLI rewrites
EXCLUDE_ENTRIES=".claude.json .credentials.json .git policy-limits.json policy-limits.json.stamp.json remote-settings.json"
# Entries whose sharing the design depends on. verify fails when one is not a live symlink.
CRITICAL_LINKS="projects settings.json settings.local.json rules skills agents hooks plugins"

if [ "$LANE_B" = "$LANE_A" ] || [ "$LANE_B" = "$LANE_A/" ]; then
  echo "claude_lane.sh: CLAUDE_LANE_B_DIR must not be ~/.claude (that is lane A)." >&2
  exit 1
fi

log()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# KEY=value reader for claude_lane.conf. The file is parsed, never sourced.
conf_get() {
  [ -f "$CLAUDE_LANE_CONF" ] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CLAUDE_LANE_CONF" | tail -1 \
    | sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}
LANE_A_EMAIL="${CLAUDE_LANE_A_EMAIL:-$(conf_get CLAUDE_LANE_A_EMAIL)}"
LANE_B_EMAIL="${CLAUDE_LANE_B_EMAIL:-$(conf_get CLAUDE_LANE_B_EMAIL)}"

# Lane A (CLAUDE_CONFIG_DIR unset) keeps its identity in ~/.claude.json; any other lane in <dir>/.claude.json.
identity_file() { if [ -n "${1:-}" ]; then printf '%s' "$1/.claude.json"; else printf '%s' "$HOME/.claude.json"; fi; }

field() {  # $1 identity file, $2 oauthAccount key -> value, or "(none)"
  local v
  v=$(jq -r --arg k "$2" '.oauthAccount[$k] // empty' "$1" 2>/dev/null) || v=""
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '(none)'; fi
}

identity() { printf '%s  org=%s  role=%s' "$(field "$1" emailAddress)" "$(field "$1" organizationName)" "$(field "$1" organizationRole)"; }

# Keychain service name the CLI and the VS Code extension derive from CLAUDE_CONFIG_DIR: unset -> the
# bare name, set -> "-" + first 8 hex of sha256 over the RAW string (no normalisation, hence #92252).
keychain_service() {
  if [ -z "${1:-}" ]; then printf 'Claude Code-credentials'
  else printf 'Claude Code-credentials-%s' "$(printf '%s' "$1" | shasum -a 256 | cut -c1-8)"; fi
}
keychain_present() { security find-generic-password -s "$(keychain_service "${1:-}")" >/dev/null 2>&1; }

# ---------------------------------------------------------------- setup / sync
link_entries() {
  local created=0 skipped=0 real=0 e name
  for e in "$LANE_A"/.[!.]* "$LANE_A"/*; do
    [ -e "$e" ] || continue
    name=$(basename "$e")
    case " $EXCLUDE_ENTRIES " in *" $name "*) continue;; esac
    if [ -L "$LANE_B/$name" ]; then
      skipped=$((skipped+1))
    elif [ -e "$LANE_B/$name" ]; then
      real=$((real+1)); warn "real (unlinked) entry in lane B: $name"
    else
      ln -s "$e" "$LANE_B/$name" && created=$((created+1))
    fi
  done
  log "links: created=$created existing=$skipped unlinked_real=$real"
  [ "$real" -eq 0 ] || warn "unlinked entries above are NOT shared with lane A. If one of them is projects/, sessions/, plugins/, backups/ or settings.json, lane B was launched before setup ran -- see README."
}

seed_identity_file() {
  local src; src=$(identity_file "")
  local dst="$LANE_B/.claude.json"
  if [ -f "$dst" ]; then log "identity file exists: $dst (kept)"; return 0; fi
  [ -f "$src" ] || { warn "missing $src -- lane A has never been logged in. Run 'claude', sign in, then re-run setup."; return 1; }
  # primaryApiKey is a credential too: lane B must never inherit lane A's way of paying.
  ( umask 077; jq 'del(.oauthAccount, .primaryApiKey) | with_entries(select(.key | test("cache"; "i") | not))' "$src" > "$dst" )
  chmod 600 "$dst"
  log "seeded $dst from lane A (oauthAccount, primaryApiKey + *cache* keys stripped)"
}

sync_mcp() {
  local src; src=$(identity_file "")
  local dst="$LANE_B/.claude.json" tmp
  [ -f "$dst" ] || { warn "lane B identity file missing; run setup"; return 1; }
  # NOTE: this ASSIGNS mcpServers, it does not merge. Lane A is the source of truth and any
  # server registered only in lane B is dropped. Register servers in lane A, then sync down.
  tmp=$(mktemp "$LANE_B/.claude.json.tmp.XXXXXX") || return 1
  jq --slurpfile a "$src" '
      .mcpServers = ($a[0].mcpServers // {})
      | .projects = ((.projects // {}) as $b
          | reduce (($a[0].projects // {}) | to_entries[]) as $e ($b;
              if ($e.value.hasTrustDialogAccepted // false)
              then .[$e.key] = ((.[$e.key] // {}) + {hasTrustDialogAccepted: true})
              else . end))' "$dst" > "$tmp" && mv "$tmp" "$dst" && chmod 600 "$dst"
  log "mcpServers synced A->B: $(jq -r '.mcpServers | keys | join(", ")' "$dst")"
  log "trust flags carried A->B: $(jq -r '[.projects[] | select(.hasTrustDialogAccepted==true)] | length' "$dst") projects"
}

cmd_setup() {
  command -v jq >/dev/null 2>&1 || { warn "jq not found -- brew install jq"; exit 1; }
  [ -d "$LANE_A" ] || { warn "lane A missing: $LANE_A -- run 'claude' once and sign in first"; exit 1; }
  [ -f "$(identity_file "")" ] || { warn "lane A has never been logged in. Run 'claude', sign in, then re-run setup."; exit 1; }
  if [ "${CLAUDE_CONFIG_DIR:-}" = "$LANE_A" ]; then
    warn "CLAUDE_CONFIG_DIR is explicitly set to the default dir. An explicit value hashes to a DIFFERENT keychain entry than unset (#92252). Unset it and re-run."
    exit 1
  fi
  # Binding check BEFORE lane B exists: seed_identity_file copies lane A's file, so a lane A signed
  # into the lane-B account would be cloned into the wrong shape. Fix lane A first.
  local ea; ea=$(field "$(identity_file "")" emailAddress)
  if [ -n "$LANE_A_EMAIL" ] && [ "$(lower "$ea")" != "$(lower "$LANE_A_EMAIL")" ]; then
    warn "lane A is signed into $ea, but it is bound to $LANE_A_EMAIL ($CLAUDE_LANE_CONF)."
    warn "In plain 'claude' run /logout, then /login as $LANE_A_EMAIL, and re-run setup."
    exit 1
  fi
  # The ordering trap: launching lane B before the symlinks exist makes the CLI create REAL
  # projects/ sessions/ plugins/ backups/ session-env/, which link_entries will refuse to replace.
  if [ -d "$LANE_B/projects" ] && [ ! -L "$LANE_B/projects" ]; then
    warn "$LANE_B/projects is a REAL directory -- lane B was launched before setup ran, so sessions are NOT shared."
    warn "Move $LANE_B aside (mv \"$LANE_B\" \"$LANE_B.broken\") and re-run setup, then log in again."
    exit 1
  fi
  # A rebuilt lane B reuses a Keychain credential left by the previous one and never shows a login.
  if [ ! -d "$LANE_B" ] && keychain_present "$LANE_B"; then
    warn "NOTE: a Keychain credential for $LANE_B already exists from an earlier lane B; the new lane will start signed into THAT account."
    warn "      To force a fresh login: security delete-generic-password -s \"$(keychain_service "$LANE_B")\""
  fi
  mkdir -p "$LANE_B" && chmod 700 "$LANE_B"
  link_entries
  seed_identity_file || exit 1
  log "lane B ready: $LANE_B  (keychain service: $(keychain_service "$LANE_B"))"
  log "next: run 'ccb' (or: claude-lane vscode) once and sign in with the SECOND account${LANE_B_EMAIL:+ ($LANE_B_EMAIL)}."
}

cmd_sync() { mkdir -p "$LANE_B"; link_entries; sync_mcp; }

# ---------------------------------------------------------------- status / verify
usage_cache() {  # best-effort; cachedUsageUtilization is an undocumented cache the CLI writes
  jq -r '.cachedUsageUtilization // empty |
         "5h=\(.utilization.five_hour.utilization // "?")% 7d=\(.utilization.seven_day.utilization // "?")% (cached \((.fetchedAtMs // 0) / 1000 | todate))"' "$1" 2>/dev/null
}

cmd_status() {
  local fa fb; fa=$(identity_file ""); fb=$(identity_file "$LANE_B")
  log "== lane A  $LANE_A  [CLAUDE_CONFIG_DIR unset]  id=$fa"
  log "   identity : $(identity "$fa")"
  log "   bound to : ${LANE_A_EMAIL:-(not set)}"
  log "   keychain : $(keychain_present "" && echo present || echo MISSING)  ($(keychain_service ""))"
  log "   usage    : $(usage_cache "$fa")"
  log "== lane B  $LANE_B  [CLAUDE_CONFIG_DIR=$LANE_B]  id=$fb"
  if [ -d "$LANE_B" ]; then
    log "   identity : $(identity "$fb")"
    log "   bound to : ${LANE_B_EMAIL:-(not set)}"
    log "   keychain : $(keychain_present "$LANE_B" && echo present || echo MISSING)  ($(keychain_service "$LANE_B"))"
    log "   usage    : $(usage_cache "$fb")"
    log "   links    : $(find "$LANE_B" -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d ' ') symlinks, projects -> $(readlink "$LANE_B/projects" 2>/dev/null || echo '(NOT LINKED)')"
  else
    log "   (not set up; run: claude-lane setup)"
  fi
  log "== keychain entries present:"
  security dump-keychain 2>/dev/null | grep -o '"svce"<blob>="Claude Code-credentials[^"]*"' | sort -u | sed 's/^/   /'
  log "== shell: CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-<unset>}"
}

# $0 acceptance test. No API call, no secret printed. Exit 0 = the two lanes are two subscriptions.
cmd_verify() {
  local fa fb ea eb aa ab oa ob ka kb rc=0 l n
  fa=$(identity_file ""); fb=$(identity_file "$LANE_B")
  ea=$(field "$fa" emailAddress);     eb=$(field "$fb" emailAddress)
  aa=$(field "$fa" accountUuid);      ab=$(field "$fb" accountUuid)
  oa=$(field "$fa" organizationUuid); ob=$(field "$fb" organizationUuid)
  ka=$(keychain_service ""); kb=$(keychain_service "$LANE_B")

  log "lane A : $ea  org=$(field "$fa" organizationName)  bound=${LANE_A_EMAIL:-(not set)}"
  log "         account=$aa  org=$oa"
  log "         keychain=$ka"
  log "lane B : $eb  org=$(field "$fb" organizationName)  bound=${LANE_B_EMAIL:-(not set)}"
  log "         account=$ab  org=$ob"
  log "         keychain=$kb"
  log ""

  [ "$ka" != "$kb" ]         || { warn "FAIL: both lanes resolve to the SAME keychain service"; rc=1; }
  keychain_present ""        || { warn "FAIL: lane A is not logged in"; rc=1; }
  keychain_present "$LANE_B" || { warn "FAIL: lane B is not logged in"; rc=1; }
  { [ "$ea" != "(none)" ] && [ "$eb" != "(none)" ]; } || { warn "FAIL: an oauthAccount is missing -- log in to that lane"; rc=1; }

  # organizationUuid is what decides which subscription is billed. It must differ, always.
  if [ "$oa" = "$ob" ] && [ "$oa" != "(none)" ]; then
    warn "FAIL: both lanes are in the SAME organization ($oa) -- they bill one subscription"; rc=1
  fi
  # Two personal Max subscriptions are two separate LOGINS. A matching email or accountUuid means
  # lane B landed on account #1 -- possibly via a SECOND ORG of that same account, which is exactly
  # why a differing organizationUuid above does NOT by itself prove a different account.
  if [ "${CLAUDE_LANE_ALLOW_SAME_ACCOUNT:-0}" = "1" ]; then
    if [ "$aa" = "$ab" ] && [ "$aa" != "(none)" ]; then
      warn "NOTE: both lanes are one account, accepted via CLAUDE_LANE_ALLOW_SAME_ACCOUNT=1 (the personal + Team shape). This is NOT Max + Max."
    fi
  else
    if [ "$ea" = "$eb" ] && [ "$ea" != "(none)" ]; then
      warn "FAIL: both lanes use the SAME login ($ea). Max + Max needs two separate logins -- lane B signed into account #1."; rc=1
    fi
    if [ "$aa" = "$ab" ] && [ "$aa" != "(none)" ]; then
      warn "FAIL: both lanes have the SAME accountUuid. Lane B is account #1, so the second Max subscription is never used."; rc=1
    fi
  fi

  # The binding: each lane must be the login it was assigned. "Differs from the other lane" cannot
  # catch two valid logins in the wrong lanes -- the checks above all pass on a swapped pair.
  if [ -n "$LANE_A_EMAIL" ] || [ -n "$LANE_B_EMAIL" ]; then
    if [ -n "$LANE_A_EMAIL" ] && [ "$(lower "$ea")" != "$(lower "$LANE_A_EMAIL")" ]; then
      warn "FAIL: lane A must be signed into $LANE_A_EMAIL but is $ea"; rc=1
    fi
    if [ -n "$LANE_B_EMAIL" ] && [ "$(lower "$eb")" != "$(lower "$LANE_B_EMAIL")" ]; then
      warn "FAIL: lane B must be signed into $LANE_B_EMAIL but is $eb"; rc=1
    fi
    if [ -n "$LANE_A_EMAIL" ] && [ -n "$LANE_B_EMAIL" ] \
       && [ "$(lower "$ea")" = "$(lower "$LANE_B_EMAIL")" ] && [ "$(lower "$eb")" = "$(lower "$LANE_A_EMAIL")" ]; then
      warn "      The two lanes are SWAPPED. /logout + /login in each lane (plain 'claude' = $LANE_A_EMAIL, 'ccb' = $LANE_B_EMAIL)."
    fi
  else
    warn "NOTE: no account binding set ($CLAUDE_LANE_CONF) -- which login belongs in which lane is not checked."
  fi

  # A token in the environment beats the Keychain in EVERY lane launched from this shell, so both
  # lanes would silently run as that one login. .claude.json above cannot show it.
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    warn "FAIL: CLAUDE_CODE_OAUTH_TOKEN is set in this shell -- every lane started from it uses that one token, not its own login."; rc=1
  fi
  { [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${ANTHROPIC_AUTH_TOKEN:-}" ]; } \
    || warn "NOTE: ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN is set in this shell. Claude Code may bill that key instead of the lane's subscription; keep it out of shells you run 'claude' / 'ccb' from."

  # The shared-config half of the design.
  for n in $CRITICAL_LINKS; do
    l="$LANE_B/$n"
    if [ ! -L "$l" ]; then
      [ -e "$LANE_A/$n" ] && { warn "FAIL: $l is not a symlink -- $n is NOT shared with lane A"; rc=1; }
    elif [ ! -e "$l" ]; then
      warn "FAIL: $l is a DANGLING symlink -> $(readlink "$l")"; rc=1
    fi
  done
  { [ -f "$LANE_B/.claude.json" ] && [ ! -L "$LANE_B/.claude.json" ]; } || { warn "FAIL: $LANE_B/.claude.json must be a REAL file, not a symlink"; rc=1; }

  # git carries NEITHER settings file (.gitignore excludes both), and settings.local.json is the
  # sole home of the hook wiring -- the external-send deny, the approval gates and the secret scan.
  # A machine missing it looks completely healthy while every safety gate is off.
  for n in settings.json settings.local.json; do
    [ -f "$LANE_A/$n" ] || { warn "FAIL: $LANE_A/$n is missing -- .gitignore excludes it, so a clone never brings it."; rc=1; }
  done
  if [ -f "$LANE_A/settings.local.json" ]; then
    local hn; hn=$(jq '[.hooks[][]?.hooks[]?] | length' "$LANE_A/settings.local.json" 2>/dev/null || echo 0)
    [ "${hn:-0}" -gt 0 ] || { warn "FAIL: settings.local.json wires 0 hook commands -- the external-send deny, approval gates and secret scan are ALL OFF."; rc=1; }
    for e in PreToolUse PostToolUse UserPromptSubmit Stop; do
      jq -e --arg e "$e" '.hooks[$e]' "$LANE_A/settings.local.json" >/dev/null 2>&1 \
        || { warn "FAIL: hook event $e is not wired in settings.local.json"; rc=1; }
    done
  fi

  # A typo'd CLAUDE_CONFIG_DIR mints an invisible third identity that `status` would never show.
  local kc; kc=$(security dump-keychain 2>/dev/null | grep -c -o '"svce"<blob>="Claude Code-credentials[^"]*"' || true)
  [ "${kc:-0}" -le 2 ] || warn "NOTE: $kc 'Claude Code-credentials*' keychain entries exist; 2 are expected (lane A + lane B). Extras are stale logins from other config dirs."

  if [ $rc -eq 0 ]; then log ""; log "PASS: two lanes, two subscriptions, shared config."; else log ""; log "FAILED -- see above."; fi
  return $rc
}

# ---------------------------------------------------------------- doctor
probe_lane() {  # $1 label, $2 lane dir or "", $3 model, $4 "" | "--with-mcp"
  local label="$1" dir="$2" model="$3" mcp="${4:-}" out rc
  local mcpargs=()
  [ "$mcp" = "--with-mcp" ] || mcpargs=(--strict-mcp-config --mcp-config '{"mcpServers":{}}')
  log "-- $label"
  if ! keychain_present "$dir"; then log "   auth: no keychain entry -> not logged in (skipping API probe)"; return; fi
  if [ -n "$dir" ]; then
    out=$(cd "$HOME" && perl -e 'alarm shift @ARGV; exec @ARGV' 120 env -u CLAUDECODE CLAUDE_CONFIG_DIR="$dir" \
          claude -p "Reply with exactly: OK" --model "$model" ${mcpargs[@]+"${mcpargs[@]}"} --output-format stream-json --verbose </dev/null 2>/dev/null); rc=$?
  else
    out=$(cd "$HOME" && perl -e 'alarm shift @ARGV; exec @ARGV' 120 env -u CLAUDECODE -u CLAUDE_CONFIG_DIR \
          claude -p "Reply with exactly: OK" --model "$model" ${mcpargs[@]+"${mcpargs[@]}"} --output-format stream-json --verbose </dev/null 2>/dev/null); rc=$?
  fi
  if [ $rc -ne 0 ] || [ -z "$out" ]; then log "   probe: FAILED (rc=$rc)"; return; fi
  printf '%s\n' "$out" | jq -r '
    select(.type=="system" and .subtype=="init") |
    "   init : model=\(.model) version=\(.claude_code_version // "?")",
    "   mcp  : \([.mcp_servers[]? | "\(.name):\(.status)"] | join(" "))"' 2>/dev/null | cut -c1-400
  printf '%s\n' "$out" | jq -r 'select(.type=="result") | "   reply: \(.result | tostring | .[0:40])  cost=$\(.total_cost_usd // 0)  is_error=\(.is_error)"' 2>/dev/null
}

cmd_doctor() {
  local model="haiku" mcp=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --full)     model=$(jq -r '.model // "haiku"' "$LANE_A/settings.json" 2>/dev/null || echo haiku) ;;
      --with-mcp) mcp="--with-mcp" ;;
    esac; shift
  done
  log "probe model: $model   mcp: ${mcp:-disabled (keeps the prompt prefix ~50k instead of ~320k tokens)}"
  probe_lane "lane A" ""        "$model" "$mcp"
  probe_lane "lane B" "$LANE_B" "$model" "$mcp"
  log "-- session dirs visible: lane A $(ls "$LANE_A/projects" 2>/dev/null | wc -l | tr -d ' ') / lane B $(ls "$LANE_B/projects" 2>/dev/null | wc -l | tr -d ' ')"
}

# ---------------------------------------------------------------- vscode
find_code() {
  command -v code 2>/dev/null && return 0
  local p
  for p in "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
           "$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"; do
    [ -x "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

# Writes lane B's VS Code settings. The markers are written UNCONDITIONALLY -- on a fresh Mac the
# main profile often has no settings.json at all, and the old "copy-then-patch" version skipped the
# whole seed in that case, leaving two identical-looking windows.
seed_vscode_profile() {
  local src="$HOME/Library/Application Support/Code/User" dst="$VSCODE_DATA_B/User"
  mkdir -p "$dst"
  if [ ! -f "$dst/settings.json" ]; then
    {
      printf '{\n'
      printf '  "window.title": "[%s] ${dirty}${activeEditorShort}${separator}${rootName}",\n' "$LANE_B_TAG"
      printf '  "workbench.colorCustomizations": {\n'
      printf '    "titleBar.activeBackground": "%s",\n'   "$LANE_B_COLOR"
      printf '    "titleBar.activeForeground": "#ffffff",\n'
      printf '    "titleBar.inactiveBackground": "%s",\n' "$LANE_B_COLOR"
      printf '    "titleBar.inactiveForeground": "#d0d0d0",\n'
      printf '    "statusBar.background": "%s",\n'        "$LANE_B_COLOR"
      printf '    "statusBar.foreground": "#ffffff"\n'
      printf '  }'
      # Merge the main profile only when it is safe: its first line must be exactly "{".
      # Otherwise the old sed trick produced two opening braces and VS Code silently discarded
      # the entire user settings file with no error.
      if [ -f "$src/settings.json" ] && [ "$(head -1 "$src/settings.json" | tr -d '[:space:]')" = "{" ]; then
        printf ',\n'
        sed '1d' "$src/settings.json"
      else
        printf '\n}\n'
      fi
    } > "$dst/settings.json"
    if [ -f "$src/settings.json" ] && [ "$(head -1 "$src/settings.json" | tr -d '[:space:]')" != "{" ]; then
      warn "main profile settings.json does not start with a bare '{' -- lane B seeded with the lane markers ONLY (merge skipped so your settings are not corrupted). Copy the rest by hand if you want them."
    fi
    log "seeded $dst/settings.json  ([$LANE_B_TAG] title + $LANE_B_COLOR title bar)"
  fi
  [ -f "$dst/keybindings.json" ] || { [ -f "$src/keybindings.json" ] && cp "$src/keybindings.json" "$dst/"; }
  [ -d "$dst/snippets" ]         || { [ -d "$src/snippets" ]         && cp -R "$src/snippets" "$dst/"; }
  return 0
}

cmd_vscode() {
  local code; code=$(find_code) || {
    warn "VS Code CLI 'code' not found. Install VS Code, then run its command palette entry \"Shell Command: Install 'code' command in PATH\"."
    exit 1; }
  [ -d "$LANE_B" ] || cmd_setup
  seed_vscode_profile
  log "launching VS Code (lane B / $LANE_B_TAG${LANE_B_EMAIL:+ / $LANE_B_EMAIL}): data=$VSCODE_DATA_B ext=$HOME/.vscode/extensions"
  # Scrub every CLAUDE*/ANTHROPIC* var inherited from the launching shell (CLAUDECODE=1 and ~16
  # others are set inside a Claude Code session), then set only the lane selector. The extension
  # HOST reads process.env.CLAUDE_CONFIG_DIR to pick its Keychain entry; the VS Code setting
  # claudeCode.environmentVariables reaches only CHILD processes, which is exactly how the
  # "UI shows account A, billing hits account B" bug (#34888 / #55621 / #87447) happens.
  # Seeded with -u CLAUDE_LANE: macOS ships bash 3.2, where "${arr[@]}" on an EMPTY array under
  # `set -u` is a fatal unbound-variable error.
  # grep -E, not a BRE "\|": alternation in a basic regex is a GNU extension.
  # ${1+"$@"} rather than "$@": no-argument "$@" under `set -u` is not safe on every bash either.
  local unset_args=(-u CLAUDE_LANE) v
  for v in $(env | grep -E -o '^(CLAUDE|ANTHROPIC)[A-Z0-9_]*=' | sed 's/=$//'); do unset_args+=(-u "$v"); done
  env "${unset_args[@]}" CLAUDE_CONFIG_DIR="$LANE_B" CLAUDE_LANE=b \
    "$code" --new-window --user-data-dir "$VSCODE_DATA_B" --extensions-dir "$HOME/.vscode/extensions" ${1+"$@"}
}

cmd_desktop() {
  mkdir -p "$DESKTOP_DATA_B"
  log "launching 2nd Claude Desktop instance: $DESKTOP_DATA_B"
  open -n -a "Claude" --args --user-data-dir="$DESKTOP_DATA_B"
}

case "${1:-}" in
  setup)   cmd_setup ;;
  sync)    cmd_sync ;;
  status)  cmd_status ;;
  verify)  cmd_verify ;;
  doctor)  shift; cmd_doctor ${1+"$@"} ;;
  vscode)  shift; cmd_vscode ${1+"$@"} ;;
  desktop) cmd_desktop ;;
  *) sed -n '2,27p' "$0"; exit 1 ;;
esac
