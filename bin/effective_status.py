#!/usr/bin/env python3
"""一个 Claude 会话「看上去」处在什么状态 —— 所有读状态的地方都从这里拿。

状态文件里每个 entry 的 `status` 是钩子写的**主 agent 自己**的状态：UserPromptSubmit
写 running，Stop 写 done。可主 agent Stop 了，不等于这个会话停了 —— 后台 subagent
（run_in_background）在主 agent Stop 之后还会接着跑，跑完才有 SubagentStop。
用户原话（2026-10-02）：「只要有一个 teammates 或者 sub agent 在干活，就算整个
Claude 的 session 在干活。」所以显示用的状态是算出来的，不是直接读 `status`。

为什么单独一个模块：读状态的有六处（status-badge.sh、list-rows.sh、jump-top.sh、
overview.py、session-digest.py、钩子里的 sync_window_badges），各自都有一套
「status/read/updated_at → 标签」的分支。如果每处再各算一遍「有没有 subagent 在跑」，
迟早有一处漏掉或者算法漂移，状态栏说在跑、picker 说完成。这里的做法是**不碰那六套
分支**：effective() 把 entry 改写成「有效」的样子（主 agent 停了但 subagent 在跑 →
status 换成 running），读者照旧用原来的分支去读，就天然一致。

只读：这里从不写状态文件，写都在 hooks/tmux_status_update.py 里。
"""
import os
import time

# 一条 subagent 记录多久没动静就不算数了。SubagentStop 漏收一次（Claude 被 kill、
# 钩子超时、机器睡过去）不该让这个窗格永远显示「在跑」—— 宁可一个真跑了三小时以上的
# 后台 subagent 提前显示成完成，也不要一个早死了的让人一直等。
# 「动静」= SubagentStart，以及这个 subagent 自己的工具调用（PostToolUse 带 agent_id，
# 钩子那边节流地刷新 seen_at，见 tmux_status_update.unblock）。
SUBAGENT_TTL = int(os.environ.get("CLAUDE_TMUX_SUBAGENT_TTL_SECS", str(3 * 3600)))


def live_subagents(entry, now=None):
    """这个 entry 里还算数的 subagent：{agent_id: record}。过期的不算。"""
    now = time.time() if now is None else now
    subs = entry.get("subagents")
    if not isinstance(subs, dict):
        return {}
    out = {}
    for aid, rec in subs.items():
        if not isinstance(rec, dict):
            continue
        seen = rec.get("seen_at") or rec.get("started_at") or 0
        if now - seen < SUBAGENT_TTL:
            out[aid] = rec
    return out


def own(entry, now=None):
    """一个窗格自己的有效状态：主 agent 加上它的 subagent。

    只在主 agent 已经停下（done / input）、却还有 subagent 在跑时才改写，改成
    running；其余原样返回同一个 dict。blocked 不动 —— 等你确认比在跑更要紧，
    而且不管是主 agent 还是 subagent 弹的权限框，都是这个窗格在等你。
    改写的是一份浅拷贝，原 entry 不变（调用方手里的 data 可能还要写回去）。"""
    if entry.get("status") not in ("done", "input"):
        return entry
    subs = live_subagents(entry, now)
    if not subs:
        return entry
    e = dict(entry)
    e["status"] = "running"
    e["busy_subagents"] = len(subs)
    return e


def effective(data, now=None):
    """{pane: 有效 entry}。读状态的地方拿它代替状态文件原文。"""
    now = time.time() if now is None else now
    return {pane: own(e, now) for pane, e in data.items() if isinstance(e, dict)}
