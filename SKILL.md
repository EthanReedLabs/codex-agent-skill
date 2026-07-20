---
name: codex-agent
description: Delegate substantial coding work from Claude Code to Codex CLI with scoped task briefs, safe background execution, resumable sessions, structured evidence, and independent verification. Use for unfamiliar repositories, exploration spanning at least three files, cross-file implementation, edits spanning more than ten lines, project-wide migrations or dependency replacements, multi-file implement/refactor/debug tasks, failing pytest or Jest suites that must be fixed until green, parallel read-only investigations, or long-running coding tasks. Trigger even when the user does not mention Codex; exclude known-location edits of ten lines or fewer and one-off standalone small scripts.
---

# Codex 委托执行协议

让 Claude Code 负责定范围、下任务书和独立验收；让 Codex CLI 负责探索、实现与测试。不要把 Codex 的自述当作验收证据。

按需读取 `references/protocol.md`：首次发射先读 §3–§5，恢复会话读 §6 和 §8，验收读 §7。复制 `BRIEF-TEMPLATE.md` 创建任务书；优先调用 `scripts/`，不要手工拼装发射、状态或验收逻辑。

## 策略自动路由（任务进来照树走，每步自动定型）

**第 0 步·定项目根（先于一切）**
项目根 = 任务目标文件所在项目的根（git 根优先，`git -C <任务路径> rev-parse --show-toplevel`），**不是会话 cwd**——多项目会话里 cwd 只有碰巧才对。`.codex-agent/` 状态一律建在该根下，各项目各一套。跨项目根的任务拆成多个工作流（细则 §3.0）。

**第 1 步·执行者**
单文件不超过 10 行且位置已知 → Claude 直改，结束 ｜ 其余命中 description 的任务 → 委托，继续。任务存在强耦合、交互式决策或外部写入审批时，先拆出可独立委托的部分。

**第 2 步·任务性质 → 模式与推理档（质量敏感为最高优先级，覆盖其他分支的档位）**
产出可从任务书机械推导 → one-shot + low 档 ｜ 需要判断、探索或验证 → 常规任务书 + 默认推理档 ｜ 质量敏感 → 默认推理档，并由指挥方执行独立验证；只有任务可安全隔离且并行收益明确时才启用多路方案。

**第 3 步·会话**
同项目同域暖会话且复用 ≤3 轮、无冲突 → resume（launch.sh 自动处理 sandbox/config 重传）｜ 否则 → 冷启动 + 任务书引用 `.codex-agent/PROJECT-MAP.md`（无地图 → 本次顺带生成）。

**第 4 步·通道**
预计少于 3 分钟且 Codex MCP 可用 → MCP 同步 ｜ 其余 → 用 `scripts/launch.sh` 后台发射，并轮询 `<slug>.status`（带超时）。以 status 为权威；失败轮可能没有 `.last.md`。

**第 5 步·批量与高风险（codex 配额充足时）**
至少 2 个独立任务可并行；同一工作区最多一个可写任务。多个可写任务必须使用独立 worktree，且任务书范围不得重叠。

**第 6 步·簿记与用户汇报**
簿记：预计 ≤2 轮 → 轻量（结束一次写日志 + ACTIVE.md 一行）｜ ≥3 轮或长期 → 全量（§8）。
**用户汇报（硬性，落盘不豁免当面汇报）**：每个工作流收尾时，实质内容必须进对话——交付物是什么与关键内容摘要、探索/审校类的**结论本体**（用户要的就是结论，不是文件路径）、验收结果、遗留风险。**禁止用"详见 xxx.md"替代实质**；文件引用只作补充。省 token 省的是过程细节（探索输出、完整日志），不是给用户的结果。

## 工具速查（脚本优先——手工组装参数是 B4/B6 事故来源）

- **发射**：`scripts/launch.sh <项目根> <slug> <read-only|workspace-write> <brief文件> [low|medium|high] [resume_id]`。脚本校验输入、锁定 slug、归档旧轮次、记录基线、限制执行时间并原子写入终态。超时会话必须先审查工作区，再显式设置 `CODEX_AGENT_TIMEOUT_REVIEWED=1` 才能 resume。
- **验收**：`scripts/verify.sh <项目根> <slug> [oneshot|full] [允许路径正则]`。workspace-write 轮必须提供允许路径正则；非零退出即未通过。超时后先审查工作区，不要直接续轮。
- **簿记**：`scripts/active-update.sh <项目根> add|update|done <slug> "<完整行>"`。
- T1 MCP 同步小轮次：`sandbox: read-only, approval-policy: never, config: {"model_reasoning_effort":"low"}, cwd: <项目根>`。
- 任务书骨架：`BRIEF-TEMPLATE.md`。
- 平台：macOS 已全量验证｜Linux 兼容（首用 T1 冒烟一次）｜Windows 走 WSL；原生 Windows 沙箱为实验性——**沙箱不等价时禁用 approval-policy: never**，细则见 protocol.md §3.6。
- 修改技能后运行 `scripts/test.sh` 与 skill-creator 的 `quick_validate.py`；分发时排除 `.git`、缓存和运行日志。
