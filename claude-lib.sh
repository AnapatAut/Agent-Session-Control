# Shared by claude-save.sh / claude-restore.sh. Resolves paths from the tmux server
# that invoked the hook, so the same scripts work against any server/@resurrect-dir.
# tmux-resurrect's scripts: the folder it registered when it loaded (in ~/.tmux/plugins or
# the XDG config's plugins folder, as TPM chose), else the default place.
_rs=$(tmux show -gqv @resurrect-save-script-path 2>/dev/null); _rs=${_rs%/save.sh}
[ -f "$_rs/helpers.sh" ] || _rs="$HOME/.tmux/plugins/tmux-resurrect/scripts"
# shellcheck source=/dev/null
. "$_rs/variables.sh"; . "$_rs/helpers.sh"
CLAUDE_MAP="$(resurrect_dir)/claude-panes.tsv"
CLAUDE_LOG="$(resurrect_dir)/claude-restore.log"
# Present while a restore is relaunching panes; save must not overwrite the map then.
CLAUDE_PENDING="$(resurrect_dir)/claude-restore.pending"
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
clog() { echo "$(date -Is) $*" >> "$CLAUDE_LOG"; }
