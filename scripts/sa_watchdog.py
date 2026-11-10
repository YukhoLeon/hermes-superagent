"""sa_watchdog.py — Super-agent 看门狗（给 Hermes cron 的 --no-agent --script 用）。

每次运行只做一件事：看看看板上有没有需要人的东西。有就打印一段简短中文，
cron 会把它送到你指定的聊天；没有就什么都不打印，cron 保持安静。
这正是 DeepSeek 原型"健康状态不占空间"的原则。

它和 Kanban 自带通知的分工：
* Kanban 在卡片 blocked / review / 崩溃的那一刻，会给有订阅的聊天推一次消息。
  这类卡看门狗不再立刻重复，只在它挂起超过 REMIND_AFTER_HOURS 还没人处理时提醒一次。
* 没有订阅的卡（dashboard / 命令行建的）、跑太久的卡、调度器诊断，Kanban 不会推，
  看门狗一发现就汇报。
* 同一批事项连续几次一样 -> 沉默；有新增或消失 -> 汇报；全部清空 -> 发一行收尾。

它只读不写：靠 `hermes kanban list / diagnostics / notify-list --json`。
Hermes 的调度器自己已经负责回收崩溃、超时、失联的 worker。

创建 cron 的命令见 D:\\Hermes\\superagent\\README.md 的"阶段四"。
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

STALE_MINUTES = 30       # running 卡超过这么久没有任何看板活动（心跳/评论/事件），就点名让人确认一下
REMIND_AFTER_HOURS = 6   # 事项挂起这么久没人处理，再提醒一次（Kanban 已通知过的卡也只在这时才说）
STATE_FILE = Path(__file__).with_name(".sa_watchdog_state.json")  # 上次汇报了什么、各事项何时首次出现


# ----------------------------------------------------------------------------
# 调 hermes CLI 读板子
# ----------------------------------------------------------------------------

def _hermes_exe() -> str:
    found = shutil.which("hermes")
    if found:
        return found
    home = os.environ.get("HERMES_HOME") or str(Path.home() / ".hermes")
    for name in ("hermes.exe", "hermes"):
        candidate = Path(home) / "bin" / name
        if candidate.exists():
            return str(candidate)
    return "hermes"


def _run_json(*args: str):
    try:
        proc = subprocess.run(
            [_hermes_exe(), *args], capture_output=True, text=True, timeout=120,
            encoding="utf-8", errors="replace",
        )
    except Exception as exc:  # hermes 不在、超时等：报出来而不是静默
        return {"_error": f"{' '.join(args)}: {exc}"}
    out = proc.stdout or ""
    start = min([i for i in (out.find("["), out.find("{")) if i >= 0], default=-1)
    if start < 0:
        return {"_error": f"{' '.join(args)} 没有返回 JSON（rc={proc.returncode}）"} if proc.returncode else []
    try:
        return json.loads(out[start:])
    except json.JSONDecodeError as exc:
        return {"_error": f"{' '.join(args)} JSON 解析失败：{exc}"}


def _tasks(status: str) -> list[dict]:
    data = _run_json("kanban", "list", "--status", status, "--json")
    if isinstance(data, dict):
        if "_error" in data:
            return [{"_error": data["_error"]}]
        data = data.get("tasks") or data.get("items") or []
    return [t for t in data if isinstance(t, dict)]


def _subscribed_task_ids() -> tuple[set[str], str | None]:
    """有通知订阅的卡：Kanban 会在终态事件发生时自己推消息。"""
    data = _run_json("kanban", "notify-list", "--json")
    if isinstance(data, dict):
        if "_error" in data:
            return set(), data["_error"]
        data = data.get("subscriptions") or data.get("items") or []
    return {str(s.get("task_id")) for s in data if isinstance(s, dict) and s.get("task_id")}, None


def _last_activity(task: dict) -> float | None:
    """这张卡最近一次看板活动的时间：`kanban show --json` 事件流（heartbeat / comment / claimed …）
    的最大时间戳，退而求其次用 started_at。拿不到就返回 None（没有证据不算卡死）。"""
    tid = task.get("id")
    if not tid:
        return None
    data = _run_json("kanban", "show", str(tid), "--json")
    stamps: list[float] = []
    if isinstance(data, dict) and "_error" not in data:
        for ev in data.get("events") or []:
            if isinstance(ev, dict):
                ts = ev.get("created_at") or ev.get("ts")
                try:
                    stamps.append(float(ts))
                except (TypeError, ValueError):
                    pass
        for c in data.get("comments") or []:
            if isinstance(c, dict):
                try:
                    stamps.append(float(c.get("created_at")))
                except (TypeError, ValueError):
                    pass
    try:
        stamps.append(float(task.get("started_at") or 0) or 0)
    except (TypeError, ValueError):
        pass
    stamps = [s for s in stamps if s > 0]
    return max(stamps) if stamps else None


def _diagnostics() -> tuple[list[dict], str | None]:
    diag = _run_json("kanban", "diagnostics", "--json")
    if isinstance(diag, dict) and "_error" in diag:
        return [], diag["_error"]
    # 实际输出形如 [{"task_id": ..., "dispatch_profiles": "any", "diagnostics": [...]}]；
    # 也兼容直接给诊断列表或 {"diagnostics": [...]} 的形状。
    top = diag if isinstance(diag, list) else [diag]
    items: list = []
    for entry in top:
        if not isinstance(entry, dict):
            continue
        nested = entry.get("diagnostics") or entry.get("items")
        if isinstance(nested, list):
            items.extend(nested)
        elif "severity" in entry:
            items.append(entry)
    return [d for d in items if isinstance(d, dict)
            and str(d.get("severity", "")).lower() in ("warning", "error", "critical")], None


# ----------------------------------------------------------------------------
# 状态记忆
# ----------------------------------------------------------------------------

def _load_state() -> dict:
    try:
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except Exception:
        return {}


def _save_state(state: dict) -> None:
    try:
        STATE_FILE.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
    except Exception:
        pass  # 记不住上次状态只会多提醒一次，不影响主流程


def _fmt(t: dict) -> str:
    return f"  {t.get('id', '?')}  [{t.get('assignee') or '-'}]  {t.get('title', '')}"


# ----------------------------------------------------------------------------
# 主流程
# ----------------------------------------------------------------------------

def main() -> int:
    now = time.time()
    errors: list[str] = []

    blocked = _tasks("blocked")
    review = _tasks("review")
    running = _tasks("running")
    for group in (blocked, review, running):
        for t in group:
            if "_error" in t:
                errors.append(t["_error"])
    blocked = [t for t in blocked if "_error" not in t]
    review = [t for t in review if "_error" not in t]
    running = [t for t in running if "_error" not in t]

    subscribed, err = _subscribed_task_ids()
    if err:
        errors.append(err)
    serious, err = _diagnostics()
    if err:
        errors.append(err)

    stale = []
    for t in running:
        last = _last_activity(t)
        if last is not None and now - last > STALE_MINUTES * 60:
            t = dict(t, _idle_minutes=int((now - last) // 60))
            stale.append(t)

    # 每个"需要人"的事项：(分组, 唯一键, 显示行, Kanban 是否已经通知过)
    items: list[tuple[str, str, str, bool]] = []
    items += [("blocked", f"blocked:{t.get('id')}", _fmt(t), str(t.get("id")) in subscribed) for t in blocked]
    items += [("review", f"review:{t.get('id')}", _fmt(t), str(t.get("id")) in subscribed) for t in review]
    items += [("stale", f"stale:{t.get('id')}", _fmt(t) + f"（已 {t.get('_idle_minutes')} 分钟无活动）", False)
              for t in stale]
    items += [("diag", f"diag:{d.get('task_id')}:{d.get('code') or d.get('kind')}",
               f"  [{d.get('severity')}] {d.get('task_id') or ''} {d.get('code') or d.get('kind') or ''} "
               f"{d.get('message') or ''}".rstrip(), False) for d in serious]
    # 错误用"哪条命令"做键而不是全文，免得超时秒数之类的细节变化导致反复汇报
    items += [("error", f"error:{e.split(':', 1)[0]}", f"  {e}", False) for e in errors]

    # ---- 首次出现时间：Kanban 已通知过的卡，挂满 REMIND_AFTER_HOURS 才由看门狗再提 -------
    state = _load_state()
    first_seen: dict[str, float] = {k: float(v) for k, v in (state.get("first_seen") or {}).items()}
    current_keys = {key for _, key, _, _ in items}
    first_seen = {k: v for k, v in first_seen.items() if k in current_keys}  # 消失的事项忘掉
    for _, key, _, _ in items:
        first_seen.setdefault(key, now)

    reportable = [
        it for it in items
        if not it[3] or (now - first_seen[it[1]]) > REMIND_AFTER_HOURS * 3600
    ]
    deferred_count = len(items) - len(reportable)

    # ---- 去重：同一批事项不重复说；挂太久再提醒一次；清空发一行收尾 ---------------------
    signature_key = json.dumps(sorted(key for _, key, _, _ in reportable), ensure_ascii=False)
    prev_key = state.get("signature", "[]")
    last_reported = float(state.get("reported_at") or 0)
    unchanged = signature_key == prev_key
    overdue = bool(reportable) and (now - last_reported) > REMIND_AFTER_HOURS * 3600

    new_state = {"signature": prev_key, "reported_at": last_reported, "first_seen": first_seen}

    if not reportable:
        if prev_key not in ("[]", ""):
            new_state.update(signature="[]", reported_at=now)
            print("Super-agent 看门狗：之前提醒的事项已全部处理完，看板恢复正常。")
        _save_state(new_state)
        return 0

    if unchanged and not overdue:
        _save_state(new_state)
        return 0

    # 集合变了但没到重提时间：只说新增的，不重印旧的；只有消失没有新增就报一行进度
    try:
        prev_keys = set(json.loads(prev_key))
    except (TypeError, ValueError):
        prev_keys = set()
    if not overdue and prev_keys:
        added = [it for it in reportable if it[1] not in prev_keys]
        remaining_old = len([it for it in reportable if it[1] in prev_keys])
        resolved = len(prev_keys - {it[1] for it in reportable})
        if not added:
            print(f"Super-agent 看门狗：之前提醒的事项已处理 {resolved} 项，还剩 {remaining_old} 项未处理。")
            new_state.update(signature=signature_key, reported_at=last_reported)
            _save_state(new_state)
            return 0
        reportable = added
        header_note = f"（新增；另有 {remaining_old} 项之前已提醒）" if remaining_old else "（新增）"
    else:
        header_note = ""

    titles = {
        "blocked": "需要你回答",
        "review": "等待审阅",
        "stale": f"运行中但超过 {STALE_MINUTES} 分钟没有任何心跳或评论，请确认是否卡死",
        "diag": "调度器诊断",
        "error": "看门狗自身出错",
    }
    sections = []
    for group in ("blocked", "review", "stale", "diag", "error"):
        lines = [line for g, _, line, _ in reportable if g == group]
        if lines:
            long_ago = group in ("blocked", "review") and any(
                it[3] for it in reportable if it[0] == group)
            suffix = f"，其中有卡已挂起超过 {REMIND_AFTER_HOURS} 小时" if long_ago else ""
            sections.append(f"{titles[group]}（{len(lines)}{suffix}）：\n" + "\n".join(lines))

    header = "Super-agent 看门狗" + header_note
    if unchanged and overdue:
        header += f"（以下事项已挂起超过 {REMIND_AFTER_HOURS} 小时仍未处理）"
    footer = "\n\n处理：hermes kanban show <id> / comment / unblock，或打开 hermes dashboard 的 Kanban 页。"
    if deferred_count:
        footer += f"\n（另有 {deferred_count} 项 Kanban 已直接通知过你，暂不重复。）"
    print(header + "\n\n" + "\n\n".join(sections) + footer)
    new_state.update(signature=signature_key, reported_at=now)
    _save_state(new_state)
    return 0


if __name__ == "__main__":
    sys.exit(main())
