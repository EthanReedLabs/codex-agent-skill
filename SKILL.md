---
name: codex-agent
description: Use when a coding task involves exploring ≥3 files, unknown code structure, cross-file changes, or >10-line edits - delegates execution to the codex MCP agent with task briefs, structured reporting, thread reuse, and log persistence. CC 作大脑（拆解/指挥/审查），codex 作执行者（探索/实现/测试）。
---

# Codex 委托执行协议（codex-agent）

分工：CC（Claude Code）只做大脑职能——拆解任务、写任务书、审查汇报、下达下一轮指令；codex 承担全部执行——探索、实现、测试。目标：省 CC 上下文 token、降延迟、汇报结构化可信、工作流可恢复。

**细则全文在 `references/protocol.md`（§1 路由表 / §2 参数与通道 / §3 前置检查与平台 / §4 任务书模板 / §5 汇报协议 / §6 thread 生命周期 / §7 验证闭环 / §8 落盘与恢复）——决策树走到哪步需要细节，就读对应节。首次在新项目使用，先通读一遍。**

## 策略自动路由（任务进来照树走，每步自动定型）

**第 0 步·定项目根（先于一切）**
项目根 = 任务目标文件所在项目的根（git 根优先，`git -C <任务路径> rev-parse --show-toplevel`），**不是会话 cwd**——多项目会话里 cwd 只有碰巧才对。`.codex-agent/` 状态一律建在该根下，各项目各一套。跨项目根的任务拆成多个工作流（细则 §3.0）。

**第 1 步·执行者**
单文件 ≤10 行且位置已知 → Claude 直改，结束 ｜ 直做预计 <60k token 且主会话不紧张且非批量 → Claude 直做，结束 ｜ 其余 → 委托，继续。

**第 2 步·任务性质 → 模式与推理档（质量敏感为最高优先级，覆盖其他分支的档位）**
产出可从任务书机械推导（成文/格式转换/模板化改动）→ **one-shot + low 档**（零探索零自验；对价：大脑把料备全，地图必须新鲜——见 §8 新鲜度戳）｜ 需要 codex 判断/探索/验证 → 常规任务书 + 按 §2 矩阵定档，**禁用 one-shot** ｜ **质量敏感**（对外交付物、核心代码、不可回滚）→ **质量优先模式**：N 路（默认 3）并行**一律禁 low**、各臂异视角（事实/一致性/遗漏），评审并行化（N 大时用 judge 臂预处理、大脑终审——实测 judge 与大脑终审方向一致率 21/21），大脑合成选优（最多一次合成轮）。**修正轮边界**：客观缺陷（格式/证据/❌/bug）允许一次原会话修正；主观质量打磨禁止串行迭代——用加并行臂解决。

**第 3 步·会话**
同项目同域暖会话且复用 ≤3 轮、无冲突 → resume（launch.sh 自动处理 sandbox/config 重传）｜ 否则 → 冷启动 + 任务书引用 `.codex-agent/PROJECT-MAP.md`（无地图 → 本次顺带生成）。

**第 4 步·通道**
预计 <3 分钟 → MCP 同步 ｜ ≥3 分钟 → 后台 exec（launch.sh 发射），**必布 Monitor 兜底**（等 `<slug>.status` 终态文件出现，带超时——以 status 为权威而非 .last.md，失败轮可能没有后者；通知实测失灵两次，禁止省略）。

**第 5 步·批量与高风险（codex 配额充足时）**
≥2 个独立任务 → 流水线指挥（跑 N 备 N+1）或并行 exec（范围隔离）｜ 高事故风险单任务 → 投机并行，N 路同发取最优（brief 复制多份、产物 staging 路径各异）。

**第 6 步·簿记与用户汇报**
簿记：预计 ≤2 轮 → 轻量（结束一次写日志 + ACTIVE.md 一行）｜ ≥3 轮或长期 → 全量（§8）。
**用户汇报（硬性，落盘不豁免当面汇报）**：每个工作流收尾时，实质内容必须进对话——交付物是什么与关键内容摘要、探索/审校类的**结论本体**（用户要的就是结论，不是文件路径）、验收结果、遗留风险。**禁止用"详见 xxx.md"替代实质**；文件引用只作补充。省 token 省的是过程细节（探索输出、完整日志），不是给用户的结果。

**实测锚点**：one-shot 机械类 ~2 分钟（codex 段 16–42s）｜ 直做 4m13s ｜ 冷启动+地图 4m24s ｜ 暖会话 4m42s ｜ 质量模式三路并行 4m10s ｜ T2/T3 代码含测试 ~9 分钟（14 轮实测全档案见本 skill 的 docs/SPEC.md §9）。

## 工具速查（脚本优先——手工组装参数是 B4/B6 事故来源）

- **发射**：任务书写入文件后 `~/.claude/skills/codex-agent/scripts/launch.sh <项目根> <slug> <sandbox> <brief文件> [low] [resume_id]`，经 run_in_background 跑。v3.1 自动：brief 非空校验（exit 4）、slug 运行锁（exit 3）、整套归档旧产物（.roundN.*，含 stderr/marker/status——防残留终态误触发 watcher）、埋 marker、显式 approval_policy、stdin 防挂、超时进程组击杀（`LAUNCH_TIMEOUT` 默认 900s，TERM→KILL）、原子终态文件 `<slug>.status`、resume 的 sandbox/config 重传（cwd 只能继承——resume 前核对项目根一致，不一致冷启动）。
- **验收**：`~/.claude/skills/codex-agent/scripts/verify.sh <项目根> <slug> [oneshot|full] [允许路径egrep]`（真验收器，非零退出=不通过：终态+越界（git 权威，含删除）+五段逐项+❌ 计数+允许路径过滤）。超时轮工作区状态未知，禁止直接续轮。
- **簿记**：`~/.claude/skills/codex-agent/scripts/active-update.sh <项目根> add|done <slug> "<完整行>"`（加锁注册/行级更新一条命令完成：owner 校验、slug 查重、死锁安全强拆、行匹配断言——不要手写锁脚本）。
- T1 MCP 同步小轮次：`sandbox: read-only, approval-policy: never, config: {"model_reasoning_effort":"low"}, cwd: <项目根>`。
- 任务书骨架：`~/.claude/skills/codex-agent/BRIEF-TEMPLATE.md`。
- 平台：macOS 已全量验证｜Linux 兼容（首用 T1 冒烟一次）｜Windows 走 WSL；原生 Windows 沙箱为实验性——**沙箱不等价时禁用 approval-policy: never**，细则见 protocol.md §3.6。
- 维护纪律：本 skill 目录自身受 git 版本管理（`~/.claude/skills/codex-agent/.git`）——**任何对 skill 文件的修订，完成后在 skill 目录 commit**（含修订原因）；分发打包时排除 `.git`。
