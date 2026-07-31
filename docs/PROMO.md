# 推广手册 (internal notes)

给 `claude-tmux-sessions` 用的发布材料:分阶段策略、各渠道现成文案、录屏配方、以及发布前的检查清单。这份文档不面向用户,是自己用的。

---

## 核心判断:分两阶段发,别一次投完

这个工具目前**所有用户可见字符串都是中文**。这决定了发布顺序:

- **阶段一(现在就能发)—— 中文技术社区。** 中文 UI 在这里是**优势**而不是缺陷,而且这批用户和"重度并行用 Claude Code"的画像高度重合。零额外成本。
- **阶段二(做完 i18n 再发)—— 英文社区。** HN / Reddit 的受众看到 README 全英文、装完界面全中文,第一条评论就是这个,会盖掉所有技术讨论。**先做英文 UI(约 50 个字符串,10 个文件),再投英文渠道。**

> 只想投一次的话:先做 i18n,然后中英文渠道一起发。反过来(先英文后 i18n)是最差的顺序——第一印象只有一次。

**两阶段都有一个共同前提:先有图。** 这类工具在任何渠道的成败几乎都取决于那张图。静图已经
有了(`docs/picker.png`、`docs/statusbar.png`,装置在 `docs/demo/`),足够支撑知乎和掘金这类
长文渠道;V2EX 和 HN 那种一眼流的地方还是得补一段 10 秒的 GIF。

---

## 发布前检查清单

- [x] 静图 `docs/picker.png` / `docs/statusbar.png` 已进 README(装置见 `docs/demo/`)
- [ ] `docs/demo.gif` 录好,并在 README 里取消那段注释 —— 静图够撑知乎/掘金,V2EX 和 HN 要动图
- [ ] README 里的 clone 地址是新账号 `threedaycat`
- [ ] 仓库加上 GitHub topics:`tmux` `claude-code` `fzf` `cli` `developer-tools` `ai-agents`
- [ ] 仓库 About 一句话描述 + 不要留空
- [ ] 在一台干净机器(或新用户目录)上真跑一遍 `install.sh`,确认零报错
- [ ] 阶段二额外:英文 UI 已合并,README 移除"UI 是中文"那段免责

---

## 录 demo GIF

**分镜(控制在 10-12 秒,越短越好):**

1. 起手在某个正常工作的 Claude pane(0.5s,交代场景)
2. 按 `prefix + g`,picker 弹出(**这是决定性的一帧** —— 满屏状态一览)
3. `j` `j` 往下两格,右侧预览跟着变(2-3s,证明预览是活的)
4. 按一个数字直接跳(1s,展示"输数字就到")
5. 落在目标 pane,停 1s 结束

**最好画面里有一个 `⏸ WAIT` 行**——那是整个工具的卖点。可以真的让某个 session 触发一次权限确认再开录。

**工具配方(推荐 asciinema,终端原生、字最清晰):**

```bash
brew install asciinema agg

# 录(录完按 ctrl-d 结束)
asciinema rec demo.cast --cols 120 --rows 32

# 转 GIF(--speed 稍微加速掉思考停顿,别超过 1.3)
agg demo.cast docs/demo.gif --font-size 16 --speed 1.2 --theme dracula
```

GIF 超过 ~5MB 就压一下(`gifsicle -O3 --lossy=60`),Reddit 和 GitHub 都对大图不友好。

也可以 QuickTime 录屏 → `ffmpeg` 转 GIF,但终端字体会糊,优先 asciinema。

---

## 阶段一:中文渠道(现在可发)

### V2EX —— 节点 `分享创造`(首选)

> **标题:** 我同时开十几个 Claude Code,写了个 tmux 状态追踪 + fzf 跳转器
>
> **正文:**
>
> 平时习惯在 tmux 里并行开很多个 Claude Code,不同项目各一个 window。痛点是:总有一个卡在权限确认上等我点同意,而我正盯着别的窗口,等发现的时候它已经干等了二十分钟。
>
> 于是用 Claude Code 的 hooks 把每个 pane 的状态记下来,归成四个:
>
> - `⏸ WAIT` 等你确认(唯一会主动报警的)
> - `▶ RUN` 正在跑
> - `✔ DONE` 干完了但你还没看
> - `✓ READ` 你已经看过了
>
> 然后两个出口:一是状态栏常驻一条(有 WAIT 就红底白字挂着,**不会自己消失**,直到你去处理);二是 `prefix + g` 弹出 fzf 列表,右边实时预览每个 pane 的画面,回车直接跳,或者直接按行号跳。
>
> 纯 tmux + bash + python3,没有常驻进程,不轮询——hooks 只在状态真的变化时才写一个小 JSON。
>
> 代码和 GIF:`<repo link>`
>
> 界面目前是中文的。设计细节写在 DESIGN.md 里,有兴趣可以看看那个双光标模式的 picker(同一个列表里 `h`/`l` 切换选 pane / 选 session)。

**发布时机:** 工作日晚上 9-11 点,V2EX 活跃度最高。

### 掘金 / 少数派

同一套内容改成文章体,标题偏"经验分享"而不是"工具发布":

- 掘金:*《并行开十几个 Claude Code 之后,我给 tmux 加了个"谁在等我"的状态栏》*
- 少数派:*《让并行的 AI 编程会话变得可管理:一个 tmux 状态追踪器的设计》*(少数派吃设计思路,把 DESIGN.md 里"为什么 WAIT 要常驻不消失"那段展开讲)

### 中文 X / 即刻

> 同时跑十几个 Claude Code,最烦的是某个卡在权限确认上干等二十分钟你才发现。
>
> 写了个 tmux 状态追踪:⏸ 等确认 / ▶ 跑着 / ✔ 完成未读 / ✓ 已读,状态栏常驻报警,一键 fzf 跳转 + 实时预览。
>
> 开源 👇 [link]

---

## 阶段二:英文渠道(i18n 之后)

### r/tmux —— 最对口,先发这个

> **Title:** I run 10+ Claude Code sessions in tmux — built a hook-driven status tracker + fzf picker so I always know which one is blocked
>
> **Body:**
>
> I kept losing track of which Claude Code pane was stalled on a permission prompt while I stared at a different window — sometimes for 20 minutes.
>
> So I wired up Claude Code's hooks to record each pane's state into one JSON file, and surfaced it two ways:
>
> - a **persistent** white-on-red `⏸ WAIT` badge in my status line that re-renders until I actually go deal with it (transient notifications kept failing me)
> - a `prefix+g` fzf picker listing every tracked pane grouped by session, with a live `capture-pane` preview that follows the cursor, and number-key jumps
>
> Four states: ⏸ waiting-on-me / ▶ running / ✔ done-unread / ✓ read. The done/read pair works like an inbox — visiting a pane marks it read, and it comes back on its own when that pane next finishes something.
>
> No daemon, no polling — plain tmux + bash + python3, hooks only fire on actual state changes.
>
> Code + demo: `<repo link>`
>
> Curious whether the two-cursor-mode picker (`h`/`l` toggles between selecting panes and selecting whole sessions, in the same list) reads intuitively to anyone else — that was the fiddliest part.

### r/ClaudeAI

同一张 GIF,标题换成受众语言:

> **Title:** Running many Claude Code sessions at once? Here's a tmux tracker that tells you which one is blocked on you

正文可以更强调 Claude Code 侧:hooks 的用法、`session_id` 关联 transcript 拿到任务行和上下文用量、以及 tmux-resurrect 之后 `claude --resume` 自动恢复。

### r/commandline

> **Title:** A hook-driven tmux status tracker + fzf picker for parallel AI agent sessions

这个社区吃实现细节,把"用 fzf 的 `transform` + `pos()` 做出 vim 式导航和双光标模式"当主线讲。

### Show HN

> **Title:** Show HN: A tmux status tracker and fzf picker for parallel Claude Code sessions
>
> **首条评论(HN 惯例,作者自己补动机):**
>
> I regularly have a dozen Claude Code sessions going across tmux windows, and kept missing permission prompts that had silently stalled a session for twenty minutes. Transient notifications didn't fix it — I'd be in another app or another Space.
>
> So the alarm here is deliberately *persistent*: a status-line badge that re-renders every refresh and only clears when you actually jump to the pane. The rest is a picker that makes "jump to whichever one needs me" a single keypress, with a live preview so I can tell what a pane is doing without switching to it.
>
> It's hooks-driven rather than polling — Claude Code's `UserPromptSubmit`/`Stop`/`Notification`/`SessionEnd` hooks write one small JSON file keyed by tmux pane id, and every reader prunes it against `tmux list-panes` so dead panes clean themselves up.
>
> Internals are written up in DESIGN.md if that's your thing. Happy to answer questions.

**时机:** 美西时间工作日早上 7-9 点(PT)发,权重最高。发完不要请人投票,HN 会惩罚。

### awesome 列表(长尾,一次性投入)

给这几个精选列表提 PR,加到 tooling / workflow 分类:

- `awesome-claude-code`(GitHub 搜,挑 star 最高的那个)
- `awesome-tmux`
- `awesome-cli-apps`(如果符合它的收录标准)

一行 PR,长期带自然流量。

---

## 通用注意事项

- **先回评论,再想下一个渠道。** 发布后头两小时的回复率直接影响排名,也是最容易拿到真实反馈的窗口。
- **一天只发一个渠道。** 同时刷屏多个 subreddit 会被判 spam。
- **别在正文里塞太多链接**,Reddit 的自动过滤对多链接新账号很敏感,一个仓库链接就够。
- **第一批 issue 优先修。** 一个 star 之后来的人会看 issue 列表活不活,早期响应速度比功能数量更重要。
