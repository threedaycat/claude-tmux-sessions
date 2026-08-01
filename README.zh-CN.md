<h1 align="center">claude-tmux-sessions</h1>

<p align="center">
  <b>在 tmux 里同时开十几个 <a href="https://claude.com/claude-code">Claude Code</a> —— 并且随时知道哪个在等你。</b>
</p>

<p align="center">
  基于 hooks 追踪每个 Claude pane 的状态,为唯一真的会把你拖住的那个状态提供一条<b>不会自己消失</b>的告警,
  再加一个一键唤出、带实时预览的 <code>fzf</code> picker 把你直接送过去。
</p>

<p align="center">
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
  <img alt="tmux + bash + python3" src="https://img.shields.io/badge/tmux%20%2B%20bash%20%2B%20python3-no%20daemon-1f425f.svg">
  <img alt="Claude Code hooks" src="https://img.shields.io/badge/Claude%20Code-hooks-D97757.svg">
</p>

<p align="center">
  <a href="README.md">English</a> · <b>简体中文</b>
</p>

<p align="center">
  <img src="docs/picker.png" alt="picker:五个 session 里追踪着 22 个 pane,收起后只剩 9 个要你处理的,其中一个卡在权限确认上,右侧是高亮 pane 的实时画面" width="960">
</p>

<p align="center">
  <sub><code>prefix + g</code> —— 追踪着 22 个 pane,收起后只剩 9 个要你处理的。
  由真实脚本渲染,数据是演示 fixture,见 <a href="docs/demo/">docs/demo</a>。</sub>
</p>

每一行都有编号 —— 按 `5`,直接落到第 5 行。光标默认停在你当前所在的那个 pane,右侧则是
**光标所在 pane 的实时画面**,随光标移动。

<!--
  还缺一段约 10 秒的 GIF(docs/demo.gif):prefix+g → 列表弹出 → j/k 往下两格、
  预览跟着走 → Enter。静图已经能撑住 README,动图是 V2EX / HN 要的。
  录制配方在 docs/PROMO.md。
-->


---

## 要解决的问题

你同时开着好几个 Claude Code —— 不同的 tmux window,不同的项目。一个在跑,一个刚跑完,
还有一个**已经卡在权限确认上二十分钟**了,悄无声息地干等,而你正盯着另一个窗口。于是你开始
逐个窗口轮着看谁需要你 —— 而这种记账活儿本来就该机器干。

这个工具把那个状态变成**环境信息**:每个 pane 通过 Claude Code hooks 自己上报状态,状态栏
在任何窗口都能看到全局,一个键唤出 picker 直接跳到该去的 pane。

没有常驻进程,也不轮询 —— hooks 只在状态真的变化时才触发,picker 只读一个很小的 JSON。

## 四个状态,靠形状分辨

|  | 状态 | 含义 |
|---|-------|------|
| `⏸` | **WAIT** | Claude 需要你明确**同意/拒绝**。它正在*干等*。唯一会主动通知你的状态。 |
| `▶` | **RUN** | Claude 在干活。你没事。 |
| `✔` | **DONE** | 跑完了,**你还没看** —— 一件待办。 |
| `✓` | **READ** | 跑完了,你也看过了。安静。 |

颜色带同样的信息(红 / 黄 / 绿 / 蓝),但图标本身可读,所以你不必依赖颜色来看这个列表。

## 你会得到什么

- **一条不会自己消失的 WAIT 告警。** 有 pane 被卡住,tmux 状态栏就挂一条红底白字的
  `⏸ WAIT`(带窗口名和已等时长),而且**每次刷新都重画,直到你去处理掉它**。另外还有一次性
  的闪屏、提示音和 macOS 通知 —— 三条通道,因为任何单独一条都可能漏掉你。
- **一个键到该去的 pane。** `prefix + g` 唤出所有被追踪 pane 的 `fzf` 列表,按 session
  分组,带跟随光标的实时预览,`Enter` 跳转。或者干脆跳过界面:`prefix + W` 直接送你到最该
  被处理的那个 pane。
- **输编号直接跳。** 按行号即到。两位数也行(`1` 再 `2` → 第 12 行),而个位数在不可能构成
  更大编号的时候依然是即时跳转。
- **它是收件箱,不是仪表盘。** 访问过的 `DONE` 会自动标记为 `READ`,`ctrl-x` 可以把不关心的
  归档掉。这两个标记都会在那个 pane **下次真的做了新事情**时自动失效 —— 所以列表能自己
  保持简短,不需要你去维护。
- **开到几十上百个也装得下。** 安静的那些 —— `READ`,以及几小时都没去看的未读 `DONE` ——
  **默认收起**,只留下真的要你处理的,并在每个 session 下面单独一行写清收了什么:
  `⋯ 收起 3 个(2 已读 · 1 搁置) · a 展开`。**只有一个安静 pane 的 session 不收** ——
  那一行提示正好把省下的一行吃掉。按 `a` 全部展开。行号是在收起**之前**就分配好的,
  所以切换显示时没有任何 pane 的号会变 —— 代价只是可见的号会跳。
- **session 模式。** `h` 把光标切到 session 标题行,预览随之变成该 session 下每个 pane 的
  一张卡片:任务行、模型、上下文用量条,以及 Claude 最后一次回复的摘录 —— 都是从各自的
  transcript 读的,不是从屏幕上刮的。一眼回答"大家都在干什么"。
- **你真实的额度用量,顺手可见。** 状态栏和 picker 底部都会显示你实际的 5 小时 / 7 天
  额度窗口(取自 Claude Code 自己缓存的 `/usage` 数据),外加从 transcript 实时算出的
  分模型 token 数。
- **tmux 崩了也能回来。** 可选的
  [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) 集成会在恢复出的每个
  pane 里重新执行 `claude --resume <session_id>`,所以回来的是你的 session,不是一堆空
  shell。

## 装之前先知道这几件事

- **界面是中文的。** 所有用户可见的字符串(`等确认`、`已运行`、`完成`)目前都是硬编码中文,
  因为作者自己看中文 —— 你在读这一版,那大概正合适。布局、图标和配色是语言中立的,代码也
  很直白,英文 / i18n 那一版不难做,[欢迎 issue 和 PR](../../issues)。
- **在 macOS 上开发、日常使用。** macOS 特有的部分只有两处:系统通知
  (`terminal-notifier`/`osascript`)和提示音(`afplay`)。其余全是纯 tmux + bash +
  python3,在 Linux 上*应该*能跑(那两个调用会静默失败),但那条路**没有测过**,所以请把
  Linux 当作未验证而不是已支持。欢迎反馈。
- **它会改你的 Claude Code 配置。** `install.sh` 会把五个脚本软链到 `~/.claude/hooks/`,
  并把四条 hook 合并进 `~/.claude/settings.json`(保留里面已有的内容)。想手动来的话先读
  `install.sh` —— 一百行左右,没有任何花活。卸载方法在下面。

## 安装

```bash
git clone https://github.com/threedaycat/claude-tmux-sessions.git ~/projects/claude-tmux-sessions
~/projects/claude-tmux-sessions/install.sh
```

**依赖:** tmux、[fzf](https://github.com/junegunn/fzf)、python3,以及一个支持 hooks 的
Claude Code。可选装 [terminal-notifier](https://github.com/julienXX/terminal-notifier),
这样点 WAIT 通知就能直接跳到对应 pane。

然后自己加上 tmux 绑定 —— 这是安装脚本刻意留给你的一步,因为大家的 tmux 配置差别太大。写进
`~/.tmux.conf`(用 [gpakosz/.tmux](https://github.com/gpakosz/.tmux) 的话写
`~/.tmux.conf.local`):

```tmux
# prefix + g → 唤出 picker,光标停在你当前所在的 pane
bind g run-shell 'tmux display-popup -w 95% -h 85% -E "CALLER_PANE=#{pane_id} ~/.claude/hooks/claude-tmux-picker.sh"'

# prefix + W → 不看界面,直接跳到最该被处理的那个 pane
bind W run-shell '~/.claude/hooks/jump-top.sh'
```

用 `tmux source-file ~/.tmux.conf` 重载。然后在任意一个**已经在跑的** Claude Code session
里执行一次 `/hooks`,让它读到新配置 —— 之后新起的 session 会自动带上。

状态栏那一条,把这个拼进你的 `status-right`:

```tmux
#(~/.claude/hooks/status-badge.sh)
```

渲染出来是额度条、仅在有东西被卡住时才出现的 WAIT badge,然后是完成未读数和运行中的计数:

<p align="center">
  <img src="docs/statusbar.png" alt="状态栏片段:5 小时额度条 32%、deploy-script 的红色 WAIT badge、然后是 2 个完成未读和 1 个运行中" width="700">
</p>

### 确认装好了

在 tmux 里的任意一个 Claude Code pane 发一条消息,然后:

```bash
python3 -c 'import json;print(json.dumps(json.load(open("'"$HOME"'/.claude/tmux-claude-status.json")),indent=2,ensure_ascii=False))'
```

应该能看到那个 pane 的条目,`"status": "running"`(跑完之后变成 `"done"`)。什么都没有?
说明 hooks 没触发 —— 在那个 session 里跑一次 `/hooks`,并检查
`~/.claude/settings.json` 里有 `tmux_status_update.py`。

### 卸载

```bash
rm ~/.claude/hooks/{tmux_status_update.py,claude-tmux-picker.sh,jump-top.sh,status-badge.sh,restore-claude.sh}
rm -f ~/.claude/tmux-claude-status.json ~/.claude/tmux-claude-restore.json ~/.claude/tmux-quota-cache.json
```

然后从 `~/.claude/settings.json` 里删掉那四条 `tmux_status_update.py` hook,再把 tmux
配置里的绑定去掉。

## picker 怎么用

- `j` / `k`(或 ↑ / ↓)在 pane 之间移动 —— session 标题行会被跳过,所以每一停都是一个真实的
  Claude pane,预览跟着走。
- **行号**直接跳过去。`/` 切换成按名字搜索(`Esc` 回到导航模式)。
- `h` / `←` 进入 session 模式;`l` / `→` 退出。
- `a` 在"只看要我处理的"(默认)和"全部 pane"之间切换。想每次都直接展开就设
  `CLAUDE_TMUX_SHOW_ALL=1`。你当前所在的那个 pane 永远不会被收起,即使它是安静的那类。
- `p` 收起预览,把整个宽度让给列表 —— 追踪十几个 pane、想扫一眼名字和路径的时候值得。再按
  一次把预览叫回来,或者用 `CLAUDE_TMUX_PREVIEW_WIDTH`(默认 `50` —— 对半分,预览就和它显示的那个 pane 差不多宽)
  改这个比例。
- `f` 把列表收窄成"只看编队" —— 只有你真的有编队时才生效,见下。
- `Enter` 跳转 · `ctrl-x` 归档当前高亮的 pane · `q` / `Esc` 关闭。

### Agent Teams(编队)

如果你在用 Claude Code 的编队,picker 会把每个队员的 pane 标上它**真正的名字和角色**
(而不是那串几个 pane 共用的窗口标题),在列表上方给每个编队加一段两行的摘要,并且给编队
那一行配一个预览:完整花名册 + 共享任务表 —— 包括那些**没有 pane、跳不过去**的成员。

编队那几行**没在用编队的人一分钱都不用付**:没有 `~/.claude/teams/` 目录时,picker 只多做
一次 `stat`,不多加一行、也不给任何一行加标注,`f` 是死键,header 里也不会提它。

但有一处相关改动**是对所有人生效的**:每行的名字现在取自那个 pane 自己的标题,而不是它所在
tmux window 的标题。**独占一个 window 的 pane,两者是同一个字符串,看不出任何区别**;而几个
Claude pane 挤在同一个 window 里时两者不同 —— window 标题是它们几个的标题拼起来的一长串 ——
所以这些行现在显示各自的名字,不再是同一坨东西重复几遍。

把 `CLAUDE_TMUX_TEAM_LABELS` 指向一个 JSON(`{"成员名": "词"}`),就能自己决定每个成员
角色标签上显示哪个词。picker 只负责把它显示出来,不解释它是什么意思。

## 为什么不直接……

- **……给 tmux 窗口起个名?** Claude Code 已经在驱动你的窗口标题了(带个转圈的 spinner),
  所以你能看出*有东西*在跑 —— 但看不出它是不是卡在等你,而且还是得逐个窗口看。WAIT 告警
  正是窗口名做不到的那部分。
- **……用 Claude Code 自己的 session 列表?** 它是 per-instance 的,而且列的是 session,
  不是*它们住在 tmux 的哪里*。这个工具是反方向的:以 pane 为主,所以"跳过去"是一个键。
- **……就等系统通知?** macOS 通知是瞬时的,你在别的 App 或别的 Space 里就很容易漏掉。这恰恰
  是这里的告警被刻意做成常驻状态栏 badge 的原因 —— 它只在你真的去处理之后才消失。

## 它是怎么工作的

Claude Code hooks 往一个文件里写状态 —— `~/.claude/tmux-claude-status.json`,按 tmux
pane id 做 key:

| Hook | 写入 |
|------|------|
| `UserPromptSubmit` | `running` |
| `Stop` | `done` |
| `Notification` | `blocked`(权限确认)或 `input`(空闲)—— hook 读通知类型来区分 |
| `SessionEnd` | 删除该条目 |

每个读取方都会先拿 `tmux list-panes -a` 把这个文件*剪一遍*,所以关掉的 pane —— 以及
Claude 退出后退回普通 shell 的 pane —— 会自己消失。picker(`bin/list-rows.sh` → `fzf`)
和状态栏(`bin/status-badge.sh`)都读它。界面上 `input`(空闲)会并入 `DONE`/`READ` 这一
对;而一个跑完了你却始终没回去看的 pane,会在 `CLAUDE_TMUX_IDLE_STALE_SECS`(默认 2 小时)
之后老化:从状态栏撤下来,并在 picker 里变暗、沉到底部。

**完整设计** —— 通知的降级链、已读/归档模型、两种光标模式和多位数编号累积、实时预览和用量
footer、字形宽度与 CJK 对齐,以及 tmux-resurrect 集成 —— 都写在
**[DESIGN.md](DESIGN.md)** 里(英文)。

## License

MIT
