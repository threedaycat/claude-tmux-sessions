#!/usr/bin/env python3
"""一个 Claude 会话「看上去」处在什么状态 —— 所有读状态的地方都从这里拿。

状态文件里每个 entry 的 `status` 是钩子写的**主 agent 自己**的状态：UserPromptSubmit
写 running，Stop 写 done。可主 agent Stop 了，不等于这个会话停了 —— 后台 subagent
（run_in_background）在主 agent Stop 之后还会接着跑，跑完才有 SubagentStop。
用户原话（2026-10-02）：「只要有一个 teammates 或者 sub agent 在干活，就算整个
Claude 的 session 在干活。」所以显示用的状态是算出来的，不是直接读 `status`。

领队和队员（Agent Teams）同理：每个队员是同一个窗口里另一个窗格里的独立 Claude，
有自己的 entry；领队显示的是它和所有队员里最忙的那个，见 effective()。

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


# 「谁更忙」。用户给的顺序是 blocked > running > done/其他，这里只多分了一档：
# **已经看过的 blocked**（read=True）排在 running 后面。读状态的地方都把它当成已打发掉
# 的提醒 —— 状态栏不数它、overview 把它归进 READ —— 如果它还能压过 running，一个队员
# 弹过、你也看过的权限框，就会让整个在跑的队在状态栏上一个数都不占。
def _weight(e):
    status = e.get("status", "running")
    if status == "blocked":
        return 1 if e.get("read") else 3
    if status in ("done", "input"):
        return 0
    return 2


def _claude_home():
    return os.environ.get("CLAUDE_HOME") or os.path.expanduser("~/.claude")


def _load_snapshot():
    """编队快照；没开过 Agent Teams 就是 None。和别处同一个门槛：一个 stat，
    不 import、不多读文件。"""
    if not os.path.isdir(os.path.join(_claude_home(), "teams")):
        return None
    import agent_teams
    return agent_teams.snapshot()


def team_links(data, snap, pane_window=None):
    """{lead 窗格: [队员窗格…]}，认不出 lead 的队不在里面。

    lead 是谁沿用 agent_teams.attach_lead 的判断（队员同窗口里正好一个别的 Claude
    就是 lead），但**在快照的一份干净拷贝上做**：调用方手里的快照可能已经按别的
    映射 attach 过（session-digest 按 session、list-rows 按窗口），直接接着用，
    不同的读者就会认出不同的 lead —— 这正是这个模块要消灭的那种分歧。

    `pane_window` 是 {窗格: 窗口标识}，调用方手里有 tmux 的实时答案就传进来；
    不传就用钩子记下的 session:window。只认状态文件里有、没归档的窗格，和
    list-rows.sh 给 attach_lead 的那份一样 —— 同窗口里的 shell 窗格不能算候选。"""
    import agent_teams
    teams = [dict(t, members=[dict(m) for m in t["members"]]) for t in snap["teams"]]
    by_pane = {m["pane"]: m for t in teams for m in t["members"] if m["pane"]}
    if pane_window is None:
        pane_window = {p: f"{e.get('session')}:{e.get('window')}"
                       for p, e in data.items() if e.get("session")}
    pane_window = {p: w for p, w in pane_window.items()
                   if p in data and not data[p].get("archived")}
    agent_teams.attach_lead({"teams": teams, "by_pane": by_pane}, pane_window)
    mates_of = {t["team"]: [m["pane"] for m in t["members"]
                            if m["is_mate"] and m["pane"]] for t in teams}
    links = {}
    for p, m in by_pane.items():
        if m.get("is_lead") and mates_of.get(m.get("team")):
            links.setdefault(p, []).extend(mates_of[m["team"]])
    return links


_UNSET = object()


def effective(data, now=None, snap=_UNSET, pane_window=None, teams=True):
    """{pane: 有效 entry}。读状态的地方拿它代替状态文件原文。

    两层，都在这里算：
      1. 每个窗格自己：主 agent + 它的 subagent（own）。
      2. 编队：领队的显示状态 = 领队自己和所有队员里最忙的那个（_weight）。队员的
         窗格就住在领队的窗口里，读者大多不给队员单独计数（状态栏、窗口徽标），
         所以队员在跑、领队却停了的时候，以前整个队看上去就是「完成」。
         借来的状态带着 `via` = 那个队员的窗格，要跳过去的地方（WAIT 的点击、
         prefix a）跳到真正在等你的那个窗格，而不是领队。
         队员自己的 entry 不变（只过第 1 层）—— picker 里领队那一行上的队员格
         要的就是每个队员自己的状态。

    `snap` 不传就自己读（有 teams/ 目录才读）；调用方已经读过就传进来，省一次。
    `teams=False` 只算第 1 层，给逐个列队员的地方用（session-digest 的名册）。"""
    now = time.time() if now is None else now
    out = {pane: own(e, now) for pane, e in data.items() if isinstance(e, dict)}
    if not teams:
        return out
    # 没有任何窗格在跑或在等，借谁都借不出更忙的状态 —— 连编队文件都不用读。
    # 这是最常见的「全都歇着」的时候，状态栏每次刷新都走这条。
    if not any(_weight(e) > 0 for e in out.values()):
        return out
    try:
        if snap is _UNSET:
            snap = _load_snapshot()
        if not snap or not snap.get("teams"):
            return out
        links = team_links(data, snap, pane_window)
    except Exception:
        return out             # 编队读坏了就当没有编队，不该让状态变空
    for lead, mates in links.items():
        mine = out.get(lead)
        if mine is None:
            continue
        best, best_pane = mine, None
        for mp in mates:
            m = out.get(mp)
            if m is None or m.get("archived") or m.get("discovered"):
                continue
            if _weight(m) > _weight(best):
                best, best_pane = m, mp
        if best_pane is None:
            continue
        e = dict(mine)
        for k in ("status", "read", "updated_at"):
            if k in best:
                e[k] = best[k]
            else:
                e.pop(k, None)
        e["via"] = best_pane
        out[lead] = e
    return out
