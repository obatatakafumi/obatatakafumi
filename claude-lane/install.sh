#!/bin/bash
# install.sh - install claude_lane v3 into ~/.claude/scripts and bind each lane to its login.
#
# usage: bash install.sh --lane-a <email> --lane-b <email>
#        bash install.sh                      # re-install, keep the existing binding
#
#   --lane-a  the login of lane A: plain `claude` and the regular VS Code window
#   --lane-b  the login of lane B: `ccb` and the VS Code window opened with `code-b` / `code-team`
#
# Run it AFTER ~/.claude exists on this Mac. It never creates ~/.claude: a pre-made ~/.claude
# makes a later `git clone ... ~/.claude` fail ("already exists and is not an empty directory").

if [ -z "${BASH_VERSION:-}" ]; then echo "install.sh: run it with bash." >&2; exit 1; fi
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
dest="$HOME/.claude/scripts"
conf="$dest/claude_lane.conf"
lane_a="" lane_b=""

while [ $# -gt 0 ]; do
  case "$1" in
    --lane-a) lane_a="${2:-}"; shift 2 ;;
    --lane-b) lane_b="${2:-}"; shift 2 ;;
    *) sed -n '2,11p' "$0"; exit 1 ;;
  esac
done

die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

[ -d "$HOME/.claude" ] || die "$HOME/.claude does not exist yet. Put ~/.claude in place first (clone / first 'claude' login), then re-run."
for f in claude_lane.sh claude_lane.zsh; do [ -f "$here/$f" ] || die "missing $here/$f"; done

if [ -n "$lane_a$lane_b" ]; then
  { [ -n "$lane_a" ] && [ -n "$lane_b" ]; } || die "give both --lane-a and --lane-b."
  for e in "$lane_a" "$lane_b"; do
    case "$e" in *@*.*) ;; *) die "not an email address: $e" ;; esac
    case "$e" in *[[:space:]\"\'=]*) die "email contains a space, quote or '=': $e" ;; esac
  done
  [ "$(lower "$lane_a")" != "$(lower "$lane_b")" ] || die "lane A and lane B must be two DIFFERENT logins."
elif [ ! -f "$conf" ]; then
  die "no binding yet: give --lane-a <email> --lane-b <email>."
fi

# Keep whatever is being replaced. Outside ~/.claude so it never lands in that repo or in lane B.
backup="$HOME/.claude-lane-backups/$(date +%Y%m%d-%H%M%S)"
save() {
  [ -f "$1" ] || return 0
  if [ -n "${2:-}" ] && cmp -s "$1" "$2"; then return 0; fi
  mkdir -p "$backup" && cp -p "$1" "$backup/" && echo "backed up $1 -> $backup/"
}

mkdir -p "$dest"
save "$dest/claude_lane.sh"  "$here/claude_lane.sh"
save "$dest/claude_lane.zsh" "$here/claude_lane.zsh"
cp "$here/claude_lane.sh"  "$dest/claude_lane.sh"
cp "$here/claude_lane.zsh" "$dest/claude_lane.zsh"
chmod +x "$dest/claude_lane.sh"
echo "installed $dest/claude_lane.sh and claude_lane.zsh"

if [ -n "$lane_a" ]; then
  save "$conf"
  ( umask 077
    { echo "# claude_lane account binding. Read by claude_lane.sh (setup / verify / status)."
      echo "# Lane A: plain 'claude' and the regular VS Code window (CLAUDE_CONFIG_DIR unset)."
      echo "CLAUDE_LANE_A_EMAIL=$lane_a"
      echo "# Lane B: 'ccb' and the VS Code window opened from a terminal with 'code-b' / 'code-team'."
      echo "CLAUDE_LANE_B_EMAIL=$lane_b"
    } > "$conf" )
  chmod 600 "$conf"
  echo "bound: lane A = $lane_a   lane B = $lane_b   ($conf)"
else
  echo "binding kept: $(grep -E '^CLAUDE_LANE_[AB]_EMAIL=' "$conf" | tr '\n' ' ')"
fi

# ~/.zshrc is in no repository, so nothing brings this line to a new Mac.
if ! grep -q claude_lane.zsh "$HOME/.zshrc" 2>/dev/null; then
  echo '[ -f ~/.claude/scripts/claude_lane.zsh ] && source ~/.claude/scripts/claude_lane.zsh' >> "$HOME/.zshrc"
  echo "added the source line to ~/.zshrc (takes effect in NEW terminals only)"
fi

# Machine check that what landed on disk is complete and is v3.
ok=1
/bin/bash -n "$dest/claude_lane.sh" && echo "OK: claude_lane.sh parses" || ok=0
if command -v zsh >/dev/null 2>&1; then zsh -n "$dest/claude_lane.zsh" && echo "OK: claude_lane.zsh parses" || ok=0; fi
grep -q 'CLAUDE_LANE_ALLOW_SAME_ACCOUNT' "$dest/claude_lane.sh" && grep -q 'CLAUDE_LANE_B_EMAIL' "$dest/claude_lane.sh" \
  && echo "OK: v3 with account binding" || { echo "FATAL: installed file is not v3"; ok=0; }
[ "$ok" = 1 ] || exit 1

if [ -d "$HOME/.claude/.git" ] && git -C "$HOME/.claude" ls-files --error-unmatch scripts/claude_lane.sh >/dev/null 2>&1 \
   && ! git -C "$HOME/.claude" diff --quiet -- scripts/claude_lane.sh; then
  echo "NOTE: ~/.claude/scripts/claude_lane.sh is tracked by git and now differs from HEAD. Commit it, or a later"
  echo "      'git reset --hard' in ~/.claude silently brings back the old version."
fi
