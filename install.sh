#!/usr/bin/env bash
# Install claude-tmux-sessions: symlinks the hook scripts into ~/.claude/hooks
# and merges the required hooks into ~/.claude/settings.json.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS_FILE="$HOME/.claude/settings.json"

echo "==> checking dependencies"
missing=()
for bin in tmux fzf python3; do
  command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "缺少依赖: ${missing[*]}" >&2
  echo "macOS: brew install ${missing[*]}" >&2
  exit 1
fi

mkdir -p "$CLAUDE_HOOKS_DIR"

echo "==> linking scripts into $CLAUDE_HOOKS_DIR"
ln -sf "$REPO_DIR/hooks/tmux_status_update.py" "$CLAUDE_HOOKS_DIR/tmux_status_update.py"
ln -sf "$REPO_DIR/bin/claude-tmux-picker.sh" "$CLAUDE_HOOKS_DIR/claude-tmux-picker.sh"
ln -sf "$REPO_DIR/bin/jump-top.sh" "$CLAUDE_HOOKS_DIR/jump-top.sh"
ln -sf "$REPO_DIR/bin/status-badge.sh" "$CLAUDE_HOOKS_DIR/status-badge.sh"
ln -sf "$REPO_DIR/bin/restore-claude.sh" "$CLAUDE_HOOKS_DIR/restore-claude.sh"

echo "==> updating $SETTINGS_FILE"
python3 - "$SETTINGS_FILE" <<'PYEOF'
import json, os, sys

path = sys.argv[1]
if os.path.exists(path):
    with open(path) as f:
        settings = json.load(f)
else:
    settings = {}

hooks = settings.setdefault("hooks", {})

def ensure_hook(event, command):
    entries = hooks.setdefault(event, [])
    for entry in entries:
        for h in entry.get("hooks", []):
            if h.get("command") == command:
                return  # already installed
    entries.append({"hooks": [{"type": "command", "command": command}]})

ensure_hook("UserPromptSubmit",
            "python3 ~/.claude/hooks/tmux_status_update.py running 2>/dev/null || true")
ensure_hook("Stop",
            "python3 ~/.claude/hooks/tmux_status_update.py done 2>/dev/null || true")
ensure_hook("Notification",
            "python3 ~/.claude/hooks/tmux_status_update.py notify 2>/dev/null || true")
ensure_hook("SessionEnd",
            "python3 ~/.claude/hooks/tmux_status_update.py clear 2>/dev/null || true")

with open(path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print("hooks merged into", path)
PYEOF

if ! command -v terminal-notifier >/dev/null 2>&1; then
  echo "==> (可选) brew install terminal-notifier — 装了之后点击 blocked 通知能直接跳到那个 pane"
fi

cat <<'EOF'

==> 安装完成，还差最后一步（手动，因为每个人的 tmux 配置不一样）：

在你的 tmux 配置文件（例如 ~/.tmux.conf 或 ~/.tmux.conf.local）里加一行绑定，
用来弹出选择器，例如绑定到 prefix+g：

    bind g run-shell 'tmux display-popup -w 95% -h 85% -E "CALLER_PANE=#{pane_id} ~/.claude/hooks/claude-tmux-picker.sh"'

必须包一层 run-shell —— display-popup 自己的 -e/-E 参数不会被 tmux 做 format
展开，只有 run-shell 的 shell-command 参数会（见 man tmux），所以 #{pane_id}
要在这里先展开成真实值，再交给 display-popup。

改完执行 `tmux source-file ~/.tmux.conf` (或对应的配置文件) 让它生效。

如果 Claude Code 会话已经在跑，需要在里面执行一次 /hooks 让新 hook 生效
（已存在的会话不会自动感知刚写入的 settings.json）。

可选：不打开 picker，直接跳到最需要处理的 pane（bind 到比如 prefix+W）：

    bind W run-shell '~/.claude/hooks/jump-top.sh'

可选：在 tmux 状态栏里常驻显示未处理数量（把这段拼进你的 status-right）：

    #(~/.claude/hooks/status-badge.sh)

可选：让每个窗口在窗口列表里直接显示自己的 Claude 状态（⏸ 等你确认 / ✔ 跑完未读 /
▶ 正在跑 / ✓ 已看过），不用打开 picker 就知道是哪个窗口：

    set -g window-status-format         '#I#{E:@claude_win} #W'
    set -g window-status-current-format '#I#{E:@claude_win} #W'

用 gpakosz/.tmux 的话，改成放进 ~/.tmux.conf.local 里的
tmux_conf_theme_window_status_format 和 ..._current_format。
渲染时不起进程：hooks 直接把 badge 写进窗口选项。

配套加上这条 hook，让「切到一个窗口」就算看过了（否则 read 只有 picker 和 prefix+W
会设，你切过去看过了，状态栏还在拿绿色催你）。它不动 blocked 的 pane —— 顺手划过一个
窗口不该把 WAIT 告警消掉：

    set-hook -g pane-focus-in 'run-shell -b "python3 ~/.claude/hooks/tmux_status_update.py mark-seen #{pane_id}"'

如果你的窗口名跟着 Claude 的 pane title 走，名字开头已经有 Claude 自己的状态字符
（✳ 空闲 / ◑◐ 转圈），它只分得清在不在跑。显示时剥掉它，只留信息更全的 badge：

    set -g window-status-format '#I#{E:@claude_win} #{s|^[^ -~] ||:window_name}'

可选：如果你用 tmux-resurrect/continuum，加上这行，恢复布局后自动
claude --resume 回到每个 pane 原来的会话（正常退出的不会被复活）：

    set -g @resurrect-hook-post-restore-all '~/.claude/hooks/restore-claude.sh'
EOF
