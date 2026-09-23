# claude_lane.zsh v3 - sourced from ~/.zshrc
#
#   Lane A = $HOME/.claude          -> plain `claude`. CLAUDE_CONFIG_DIR must stay UNSET.
#   Lane B = $CLAUDE_LANE_B_DIR     -> `ccb` (CLI) / `code-b` or `code-team` (its own VS Code window)
#
# Which login belongs in which lane lives in ~/.claude/scripts/claude_lane.conf (written by
# install.sh); `claude-lane verify` fails when a lane is signed into the other account.
#
# Never export CLAUDE_CONFIG_DIR=$HOME/.claude. An explicit value hashes to a DIFFERENT Keychain
# entry than leaving it unset (anthropics/claude-code #92252), so lane A would look logged out and
# a fresh login there would mint a third, orphaned credential. Guard it in case something upstream
# sets it.
if [[ "${CLAUDE_CONFIG_DIR:-}" == "$HOME/.claude" ]]; then unset CLAUDE_CONFIG_DIR; fi

export CLAUDE_LANE_B_DIR="${CLAUDE_LANE_B_DIR:-$HOME/.claude-b}"
export CLAUDE_LANE_B_TAG="${CLAUDE_LANE_B_TAG:-MAX-B}"

# Lane B CLI. Works from any terminal, including one inside the lane-A VS Code window.
# `env -u CLAUDECODE` matters: that variable is set inside a Claude Code session and would
# otherwise make a nested launch think it is already inside one.
ccb() { env -u CLAUDECODE CLAUDE_CONFIG_DIR="$CLAUDE_LANE_B_DIR" claude "$@"; }

# Force lane A, even from inside a lane-B terminal.
cca() { env -u CLAUDECODE -u CLAUDE_CONFIG_DIR claude "$@"; }

alias claude-lane="$HOME/.claude/scripts/claude_lane.sh"
alias code-b="$HOME/.claude/scripts/claude_lane.sh vscode"

# Kept on purpose: this is the invocation already in muscle memory. Identical to code-b.
alias code-team="$HOME/.claude/scripts/claude_lane.sh vscode"
alias cct="ccb"
alias ccm="cca"

# Prompt marker so a lane-B terminal is unmistakable. With two personal Max accounts the two lanes
# look identical everywhere except the email address, so this marker and the blue VS Code title bar
# are the only things standing between you and running work on the wrong subscription.
if [[ "${CLAUDE_CONFIG_DIR:-}" == "$CLAUDE_LANE_B_DIR" ]]; then
  export CLAUDE_LANE=b
  PROMPT="%F{blue}[${CLAUDE_LANE_B_TAG}]%f $PROMPT"
else
  export CLAUDE_LANE=a
fi
