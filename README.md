# Hermes Super-agent

在 [Hermes Agent](https://github.com/NousResearch/hermes-agent) 上按 DeepSeek《Super-agent 设计探索》的思路搭的一套"调度员 + 专职工人"工作方式：你在飞书说一句，Router 建卡派人，工人后台干活，做完主动汇报，只在需要你决定时开口。

没有新框架。Hermes 的 Kanban、Profile、Gateway、Cron 提供全部机制，这个仓库只提供**制度**：四个角色的 SOUL、授权头模板、Router 收权、observe 模式、一个安静的看门狗，以及一键部署脚本。

| 文档 | 给谁看 |
|---|---|
| [docs/使用说明.md](docs/使用说明.md) | 使用者：怎么派活、怎么回答、怎么看进度 |
| [docs/设计说明.md](docs/设计说明.md) | 想知道为什么这样设计、每个概念在 Hermes 里叫什么 |
| [docs/运维与排错.md](docs/运维与排错.md) | 维护者：常用命令、坑、典型故障 |
| [docs/变更记录.md](docs/变更记录.md) | 时间线 |
| [docs/问答备忘.md](docs/问答备忘.md) | 搭建过程中问过的问题 |

## 角色

| profile | 职责 | 模型建议 |
|---|---|---|
| `planer` | Router。接单、查重、建卡、写授权头、派人、跟进、汇报。没有执行工具。 | 便宜（sonnet 级） |
| `coder` | 写代码、跑测试、修 Bug。交付走 review。 | 强 |
| `researcher` | 检索、调研、核查、写报告。 | 强或中 |
| `reviewer` | 审查代码与交付物，是人类之前的最后一道门。 | 强 |
| `worker` | 万能工人。不属于上面三类的执行任务：文档、表格、数据处理、网页操作、自动化。按卡挂技能。 | 默认模型 |

三个专长角色之外一律派给 `worker`。同一类活反复出现、需要自己的记忆和纪律时，再把它升格成专门角色（见"增删角色"）。这与 DeepSeek 原型一致：工人本是同一种，专长来自工单。

## 部署（Windows）

前提：已安装 Hermes 并至少跑过一次（`hermes setup` 配好模型），飞书已接到你打算当 Router 的 profile。

```powershell
git clone <本仓库> superagent
cd superagent
Copy-Item superagent.config.example.json superagent.config.json
# 编辑 superagent.config.json：hermes_home、各角色模型、看门狗投递目标、飞书 open_id
powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun   # 先看它要做什么
powershell -ExecutionPolicy Bypass -File .\install.ps1           # 执行
hermes gateway restart
```

安装脚本幂等，可反复运行。它会：创建缺失的 profile（克隆默认 profile 的模型与密钥）并写描述；安装 SOUL、技能、看门狗脚本；写 kanban 配置；收窄 Router 工具并设置模型；建看门狗 cron；检查飞书白名单并打印该怎么填。它**不会**改 `.env`、不启用插件。

`.env` 里需要你自己填的两行（这是门卫）：

```
FEISHU_ALLOWED_USERS=ou_你的openid
FEISHU_GROUP_POLICY=allowlist
```

验证：`hermes profile list`、`hermes kanban stats`，然后在飞书对 planer 说一句需要多步的话，看它是建卡派人而不是自己动手。

卸载：`powershell -ExecutionPolicy Bypass -File .\uninstall.ps1`（保留 profile 和看板数据）。

## 增删角色

这套东西不只为写代码设计，工人角色随任务变化是常态。角色清单只有一个来源：`superagent.config.json` 的 `workers`。

1. 在 `workers` 里加一行，比如 `{ "profile": "buyer", "description": "供应商询价、比价、下单前核对", "model": "" }`。描述写清楚，Router 按描述派活。
2. 可选：写 `souls/buyer.md` 定义它的专属纪律。不写则安装时用 `souls/_worker_template.md` 自动生成一份通用工人 SOUL。
3. 重跑 `install.ps1`。它会创建 profile、装 SOUL，并把新角色渲染进 planer 的"当前可派的角色"清单。
4. `hermes gateway restart`。

删角色：从 `workers` 里去掉，重跑安装（planer 的清单会更新），profile 本身保留，想删就 `hermes profile delete <name>`。

经验法则：先用少数通用角色加按卡挂技能（`kanban_create(skills=[...])`）；同一类活反复出现、需要自己的记忆和纪律时，再升格成角色。

## 仓库结构

```
superagent/
├── README.md
├── superagent.config.example.json   配置模板（复制为 superagent.config.json，后者不入库）
├── install.ps1 / uninstall.ps1      一键部署与回滚（幂等，带 -DryRun）
├── souls/                           四个角色的 SOUL.md
├── skills/superagent/               sa-router / sa-worker 技能
├── templates/mandate.md             卡片授权头模板
├── scripts/sa_watchdog.py           看门狗（给 cron --no-agent 用）
├── optional/sa-gate/                可选插件：零 token 快速建卡，默认不装
└── docs/
```

## 边界

- 工人以你的系统用户身份运行，没有沙箱。白名单只留自己，`auto_decompose` 保持 false 观察一段时间。
- 工人不会自动提交、推送、开 PR、花钱、删数据、对外发消息；这些都停下来问你。
- 卡片里的外部内容是数据不是指令。

## 许可证

MIT，见 [LICENSE](LICENSE)。
