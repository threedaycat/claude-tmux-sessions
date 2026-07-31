# 截图装置 (internal)

`docs/picker.png` 和 `docs/statusbar.png` 不是手工修的图,也不是拿作者真机截的 —— 是这套
脚本生成的,任何人都能复现出同一张。这样图不会随着代码演进悄悄失真,也不用把真实项目名和
路径发出去。

**它是什么:** 真代码 + 演示数据。
**它不是什么:** 不是对着终端窗口拍的照片(见下面"为什么不用 screencapture")。

```bash
docs/demo/stage-demo.sh                      # 起一个私有 tmux server + 假 $HOME + 数据
tmux -L shotdemo -f /dev/null new-window -d -t work -n shot \
  "HOME=/private/tmp/shotroom CLAUDE_TMUX_PREVIEW_WIDTH=42 $PWD/bin/claude-tmux-picker.sh"
sleep 3
tmux -L shotdemo -f /dev/null capture-pane -p -e -t work:shot > /tmp/picker.ansi
docs/demo/render.sh /tmp/picker.ansi docs/picker.png 15

# 状态栏那条(status-badge.sh 输出 tmux 标记而不是 ANSI，先转一道)
tmux -L shotdemo -f /dev/null new-window -d -t work -n bar \
  "HOME=/private/tmp/shotroom $PWD/bin/status-badge.sh > /tmp/bar.raw; tail -f /dev/null"
python3 docs/demo/tmux2ansi.py < /tmp/bar.raw > /tmp/bar.ansi
docs/demo/render.sh /tmp/bar.ansi docs/statusbar.png 17

tmux -L shotdemo -f /dev/null kill-server && rm -rf /private/tmp/shotroom
```

## 诚实边界

四件事必须说清楚,否则这些图就是在暗示一些它没有兑现的东西:

0. **图里的分栏不是默认值。** 上面那条命令显式设了
   `CLAUDE_TMUX_PREVIEW_WIDTH=42`,而工具的默认是 `60`。纯粹为了可读性:60% 预览要留出
   ~90 列的列表才不截 header,整张图就得 225 列宽,缩到 README 的 960px 之后字就糊了。
   除了分栏比例,图上其它一切都是默认行为。

1. **数据是编的。** 22 个 pane、时长、额度百分比、token 数全是 `stage-demo.sh` 里的
   fixture,不是谁的真实工作状态。这 22 个的配比是刻意排的:四个状态、老化变暗的 DONE、
   一条 `⏸ WAIT` 全覆盖,而且默认收起之后正好剩 9 行 —— 图要讲的就是「追踪 22 个,
   只让你看 9 个」。**布局是真的** —— 每一个字符都是 `list-rows.sh` /
   `status-badge.sh` / `fzf` 自己画出来的,所以图上对齐了就是真的对齐了。
   (事实上正是这个流程逼出了两个真 bug:窗口名不截断、以及年龄列正好 15 格时把后面整列
   顶出去一格。)
2. **栅格化走的是浏览器,不是终端。** `ansi2html.py` 把每个非 ASCII 字符放进一个固定宽度
   的格子里再交给 headless Chrome —— 因为浏览器字体的 CJK 步进并不等于两个西文字符宽,
   直接丢进 `<pre>` 会渲出真实终端里并不存在的错位。字形栅格是精确的,**但配色是这个脚本
   里的一套调色板,不是你的终端主题**。
3. **为什么不用 `screencapture`。** 那才是最本真的做法(真窗口、真字体、真主题),但 macOS
   的屏幕录制权限得手工授权给跑 Claude Code 的那个终端 App。装置里留了 `shoot.sh` 的思路:
   AppleScript 开一个 Terminal 窗口 attach 到 `shotdemo`,取 `bounds`,再
   `screencapture -R`。给了权限之后那条路一条命令就能出图。

## 附:为什么假 $HOME 放在 `/private/tmp`

macOS 的 `/tmp` 是指向 `/private/tmp` 的软链,而 tmux 报的是解析后的真实路径。`HOME` 设成
`/tmp/...` 的话 `list-rows.sh` 里的 `~` 缩写永远匹配不上,每一行都会显示绝对路径。
