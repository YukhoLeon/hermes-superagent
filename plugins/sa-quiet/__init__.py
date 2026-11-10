"""sa-quiet — 让看板终态只由 Router 来说，不重复推送。

背景：在聊天里让 planer 建卡时，Hermes 会自动给这张卡订阅发起聊天，模式写死为
``notify+wake``：先推一条格式化的被动通知（含附件），再叫醒 planer 让它自己汇报。
用户在飞书里就会看到两遍。Hermes 没有配置项能只要后半截。

做法：``kanban_task_claimed`` 钩子在调度器进程里、卡片被工人领取的那一刻触发。此时把
这张卡所有 ``notify+wake`` 的订阅改成 ``wake``（只叫醒，不推被动消息）。终态事件照常
触发 planer 的回合，planer 按自己的 SOUL 汇报一次。

边界：
* 只改 ``notify+wake``，不碰 ``notify``（那是脚本或命令行明确要的被动通知）。
* 可用 ``platforms`` 限定只对某些平台生效（默认全部）。
* 代价：planer 被叫醒后若出错没回话，你收不到这张卡的消息；看门狗会在 6 小时后兜底。

配置（可选）::

    plugins:
      entries:
        sa-quiet:
          settings:
            platforms: [feishu]     # 留空 = 所有平台
"""

from __future__ import annotations

import logging
from typing import Any, Optional

logger = logging.getLogger(__name__)

PLUGIN_ID = "sa-quiet"


def quiet_subscriptions(task_id: str, board: Optional[str], platforms: list[str]) -> int:
    """把这张卡的 notify+wake 订阅改成 wake；返回改了几条。失败只记日志，绝不抛出。"""
    try:
        from hermes_cli import kanban_db_connect as kbc
        from hermes_cli import kanban_db_notify as kbn
    except Exception:
        logger.debug("sa-quiet: kanban modules unavailable", exc_info=True)
        return 0
    changed = 0
    try:
        with kbc.connect_closing(board=board) as conn:
            for sub in kbn.list_notify_subs(conn, task_id):
                if sub.get("delivery_mode") != "notify+wake":
                    continue
                if platforms and sub.get("platform") not in platforms:
                    continue
                meta = sub.get("delivery_metadata")
                if isinstance(meta, str):
                    try:
                        import json
                        meta = json.loads(meta) if meta else None
                    except ValueError:
                        meta = None
                kbn.add_notify_sub(
                    conn, task_id=task_id, platform=sub["platform"], chat_id=sub["chat_id"],
                    thread_id=sub.get("thread_id"), user_id=sub.get("user_id"),
                    user_id_alt=sub.get("user_id_alt"), chat_type=sub.get("chat_type"),
                    notifier_profile=sub.get("notifier_profile"), delivery_mode="wake",
                    delivery_metadata=meta if isinstance(meta, dict) else None,
                )
                changed += 1
    except Exception:
        logger.warning("sa-quiet: failed to quiet subscriptions for %s", task_id, exc_info=True)
    if changed:
        logger.info("sa-quiet: %s -> wake-only for %d subscription(s)", task_id, changed)
    return changed


def register(ctx) -> None:
    def _platforms() -> list[str]:
        try:
            value = ctx.get_config("platforms", []) or []
        except Exception:
            value = []
        return [str(p) for p in value]

    def on_claimed(task_id: str = "", board: Optional[str] = None, **_: Any) -> None:
        if task_id:
            quiet_subscriptions(task_id, board, _platforms())

    ctx.register_hook("kanban_task_claimed", on_claimed)
