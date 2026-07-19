# Codex 委托执行结构（codex-agent）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地「CC 大脑 + codex 执行者」委托结构：创建全局 skill `codex-agent` 承载完整协议，并在全局 CLAUDE.md 加触发规则，实现自动路由。

**Architecture:** 协议全文放在按需加载的 skill 里（不占日常上下文）；CLAUDE.md 只放 3 行触发规则。skill 内容 = spec 第 1–8 节（路由表、参数矩阵、安全护栏、任务书模板、汇报协议、thread 生命周期、验证闭环、落盘机制）。

**Tech Stack:** Claude Code skill（Markdown + YAML frontmatter）、codex MCP（`mcp__codex__codex` / `mcp__codex__codex-reply`）。

**Spec:** `docs/superpowers/specs/2026-07-16-codex-agent-delegation-design.md`

## Global Constraints

- skill 路径固定：`~/.claude/skills/codex-agent/SKILL.md`
- 协议中的五段汇报标题、参数矩阵取值必须与 spec 逐字一致
- `~/.claude` 与本项目均非 git 仓库：无 commit 步骤（spec §3 的 git 护栏针对被委托的项目工作区，不针对这两处配置文件）
- CLAUDE.md 追加规则 ≤5 行，不得把协议细节写进 CLAUDE.md

---

### Task 1: 创建 codex-agent skill

**Files:**
- Create: `~/.claude/skills/codex-agent/SKILL.md`

**Interfaces:**
- Produces: 名为 `codex-agent` 的全局 skill，后续会话中通过 Skill 工具调用；Task 2 的触发规则引用该名称。

- [ ] **Step 1: 写入 SKILL.md 全文**

写入以下完整内容（协议正文与 spec 第 1–8 节一致）：

````markdown
---
name: codex-agent
description: Use when a coding task involves exploring ≥3 files, unknown code structure, cross-file changes, or >10-line edits - delegates execution to the codex MCP agent with task briefs, structured reporting, thread reuse, and log persistence. CC 作大脑（拆解/指挥/审查），codex 作执行者（探索/实现/测试）。
---

# Codex 委托执行协议（codex-agent）

分工：CC（Claude Code）只做大脑职能——拆解任务、写任务书、审查汇报、下达下一轮指令；codex 承担全部执行——探索、实现、测试。目标：省 CC 上下文 token、降延迟、汇报结构化可信、工作流可恢复。

## 1. 任务路由表

| 类型 | 判定标准 | 执行者 |
|---|---|---|
| T0 微编辑 | 单文件、位置已知、改动 ≤10 行 | Claude 直接用 Edit 工具改 |
| T1 探索/定位 | 需要读 ≥3 个文件，或代码结构未知 | codex（只读） |
| T2 实现/重构 | 跨文件改动，或单文件 >10 行 | codex（可写） |
| T3 测试修错循环 | 跑测试→修→再跑直至通过 | codex（可写，续接 T2 的 thread） |

边界与升级规则：
- 体量拿不准时，默认按更大的类型处理。
- T0 进行中发现超出边界 → 立即停手，把已知信息写成任务书升级为 T2。
- T1 例外：架构决策性质的探索（方案选型、依赖梳理）不降推理档，用默认档。
- 活跃 thread 涉及的路径范围内，Claude 不做 T0 微编辑；确有必要改动，必须在下一次 codex-reply 中告知改动点。

## 2. 调用参数矩阵（每次调用显式传参，不改全局 config.toml）

| 类型 | sandbox | approval-policy | config 覆盖 | cwd |
|---|---|---|---|---|
| T1（常规定位） | `read-only` | `never` | `{"model_reasoning_effort": "low"}` | 项目根，显式传 |
| T1（架构决策类） | `read-only` | `never` | 无 | 项目根，显式传 |
| T2 / T3 | `workspace-write` | `never` | 无 | 项目根，显式传 |

## 3. 前置检查与安全护栏（工作流启动前依次执行）

1. git 检查：项目非 git 仓库 → 先征得用户同意后 `git init` 并做初始 commit；用户拒绝则降级——codex 汇报必须列完整改动文件清单、Claude 逐一抽查，并明确告知用户此模式无回滚能力。
2. 检查点：每轮 T2/T3 开始前工作区必须处于干净 commit 点（未提交改动先 commit 或 stash）。
3. 禁止事项固定项：破坏性 git 操作（reset --hard、push --force、改写历史）、删除非任务范围文件、修改全局配置。
4. 信任前提：新项目首次使用前确认 `~/.codex/config.toml` 中该目录为 `trusted`。

## 4. 任务书模板（codex 首轮 prompt 固定结构）

```
## 目标
（一句话说清要达成什么）

## 范围
涉及路径：<明确列出>
禁止改动：破坏性 git 操作；删除非任务范围文件；修改全局配置；<任务特定项>

## 已知上下文
（Claude 已掌握的信息直接贴入：目录结构摘要、关键代码片段、上一轮结论。
 这是让 codex 跳过探索阶段的关键提速点。
 若存在历史日志文件，给出路径让 codex 自行阅读，不粘贴内容。）

## 日志文件
本工作流日志：<项目根>/.codex-agent/<工作流slug>.md
每轮结束将完整汇报追加写入该文件（格式见汇报协议）。

## 完成标准
（可逐条验证的条目，codex 汇报时逐条对照）

## 体量与熔断
本轮任务体量控制在约 10 分钟内可完成；
（T3 专用）测试修错尝试 3 次仍未通过 → 停止并汇报当前状态。
```

拆轮规则：MCP 调用同步阻塞，预估超约 10 分钟的任务必须拆成多轮，通过同一 thread 逐轮下发。

## 5. 汇报协议（通过 developer-instructions 参数注入，全文固定）

```
每轮结束时，你必须以下列五段格式汇报，标题一字不差：

## 结果
改动摘要，一律用 文件:行号 引用；探索类任务给结论和证据位置

## 过程
关键步骤，最多 5 条

## 遇到的问题

## 解决方式

## 遗留风险与建议
无则写"无"

约束：
- 不要向汇报中粘贴大段代码（>10 行），只给 file:line 引用。
- 完成标准逐条标注 ✅/❌，每个 ✅ 必须附可复核的原始证据：
  执行的命令原文、exit code、输出末尾 5 行。禁止只写结论。
- 最终消息给精简版（每段 ≤3 条）；同时把完整版汇报（五段全文 +
  附录：关键命令完整输出、diff 摘要）追加写入任务书指定的
  日志文件，本轮标题为 `# Round N (threadId: xxx)`。
```

T1 只读沙箱无法写文件，其汇报由 Claude 收到后写入同一日志文件。

协议容错：汇报格式不符、证据缺失或漏写日志文件时，用一次 codex-reply 纠正补交，不重开 thread；纠正后仍不符按"无实质进展"计入熔断。

## 6. Thread 生命周期与异常处理

- 一个工作流 = 一个 thread。首轮用 `codex` 工具，之后一律 `codex-reply` + `threadId`。
- Claude 每次收到汇报后在可见回复中记录 threadId。
- 新的独立任务开新 thread，不复用旧 thread。
- 熔断：同一 thread 连续 2 轮无实质进展 → 放弃，重新分析、换策略、开新 thread。
- 冷启动：开新 thread 时，任务书「已知上下文」给日志文件路径让 codex 自行阅读，不粘贴历史内容。
- threadId 失效降级：codex-reply 报错（thread 不存在）→ 不重试，直接冷启动开新 thread。
- 同一 thread 内不重复传递上一轮内容——codex-reply 已保有全部历史。

## 7. 验证闭环（Claude 侧）

1. codex 按协议汇报（含原始证据）。
2. `git diff --stat` 核对改动范围（非 git 降级模式：核对汇报中的改动文件清单）。
3. 只抽查关键 hunk，不重读整个文件。
4. 每个 ✅ 必须有原始证据（命令 + exit code + 输出尾行），只有结论视为 ❌。
5. 最终验收：工作流收尾时 Claude 自己执行一次测试/验证命令，不全信汇报。
6. 全 ✅ 且最终验收通过才收尾；出现 ❌ 或遗留风险 → codex-reply 下修正指令。

## 8. 汇报落盘与恢复

日志文件：`<项目根>/.codex-agent/<工作流slug>.md`（跨会话持久；git 仓库中加入 .gitignore）。

- 写入分工：T2/T3 由 codex 自行追加（指令在汇报协议中）；T1 由 Claude 代写；文件头（任务总目标、threadId、任务书原文）由 Claude 在工作流开始时写入。
- Claude 读取规则——仅三种情况读日志：① 上下文压缩后找回历史/threadId；② 新会话恢复工作流；③ 需核对某轮完整细节。正常轮次不得重读（汇报已在上下文中，重读是双倍开销）。

状态清单：`<项目根>/.codex-agent/ACTIVE.md`，每行一个工作流：
`- <slug> | 状态: active/blocked/done | threadId: xxx | 轮次: N | 下一步: <一句话>`
Claude 在每轮验收后、发起下一轮之前更新对应行；完结改 done，done 条目下次更新时移除。

恢复流程（压缩 / /clear / 会话切换通用）：
1. 锚点在全局 CLAUDE.md（唯一每个上下文窗口都重新注入的地方）："开始代码工作前，若项目根存在 .codex-agent/ACTIVE.md，先读取并恢复未完结工作流"。
2. 读 ACTIVE.md → 定位未完结工作流 → 读对应日志的文件头与最后一轮汇报。
3. 先试 codex-reply + 记录的 threadId（MCP server 未重启则零成本恢复）；失败则冷启动（见第 6 节）。
4. 轮次边界纪律：状态更新先于下一轮下发，任意时刻被重置最多丢失当前一轮。

多工作流切换：各自独立日志 + ACTIVE.md 各占一行；切回前先读状态行，不依赖对话记忆。

多终端 / 多项目并发：
- 多项目：skill 全局唯一，状态严格项目本地化（.codex-agent/ 在各项目根），cwd 每次显式传，项目间互不干扰。
- 多终端同项目：每个会话有自己的 codex mcp-server 进程，thread 不跨终端存活。工作流归属创建它的会话；接管他人 active 工作流必须经用户确认并走冷启动。
- ACTIVE.md 更新一律用行级 Edit（精确替换本工作流那一行），禁止整文件重写（初次创建除外）。
- slug 唯一性：开新工作流前查 ACTIVE.md，slug 被 active 占用则换名。
- 范围隔离：同项目多会话并行委托时，各任务书「涉及路径」不得重叠；git 检查点发现他人未提交改动，不得 stash，提醒用户处理。

- 清理：验收完成后日志保留归档，是否删除由用户决定。
````

- [ ] **Step 2: 校验文件结构**

Run: `head -5 ~/.claude/skills/codex-agent/SKILL.md`
Expected: 输出以 `---` 开头，含 `name: codex-agent` 与 `description:` 行。

- [ ] **Step 3: 校验协议关键内容完整**

Run: `grep -c '^## ' ~/.claude/skills/codex-agent/SKILL.md && grep -n 'model_reasoning_effort\|approval-policy\|threadId\|codex-agent' ~/.claude/skills/codex-agent/SKILL.md | head -8`
Expected: 章节计数 ≥8；四个关键词均有命中。

### Task 2: 追加 CLAUDE.md 触发规则

**Files:**
- Modify: `~/.claude/CLAUDE.md`（不存在则创建）

**Interfaces:**
- Consumes: Task 1 的 skill 名称 `codex-agent`。
- Produces: 每个会话常驻的自动路由规则。

- [ ] **Step 1: 查看现有内容，确认无冲突规则**

Run: `cat ~/.claude/CLAUDE.md 2>/dev/null || echo "(不存在)"`
Expected: 现有内容或 "(不存在)"。若已有 codex 相关规则，改为合并而非重复追加。

- [ ] **Step 2: 追加触发规则（全文如下）**

```markdown

## Codex 委托
凡涉及代码探索或修改的任务（需读 ≥3 个文件、跨文件改动、或单文件改动 >10 行），先调用 codex-agent skill，按其路由表委托给 codex MCP 执行。仅微编辑（单文件、位置已知、≤10 行）由 Claude 直接完成。
开始代码工作前，若项目根存在 .codex-agent/ACTIVE.md，先读取并恢复未完结的委托工作流（上下文压缩、/clear、会话切换后同样适用）。
```

- [ ] **Step 3: 校验**

Run: `grep -A2 '## Codex 委托' ~/.claude/CLAUDE.md`
Expected: 完整输出上述规则文本。

### Task 3: 端到端冒烟测试（真实 T1 委托）

**Files:**
- Create（由测试产生）: `<测试项目根>/.codex-agent/smoke-test.md`

**Interfaces:**
- Consumes: Task 1 的协议全文（任务书模板、汇报协议、参数矩阵）。

- [ ] **Step 1: 按协议发起一次 T1 委托**

调用 `mcp__codex__codex`，参数照参数矩阵 T1 行：`sandbox: "read-only"`、`approval-policy: "never"`、`config: {"model_reasoning_effort": "low"}`、`cwd: "/Users/eric/HF-Distillation"`（已在 `~/.codex/config.toml` 中 trusted；只读任务不需要 git 护栏）、`developer-instructions: <汇报协议全文，取自 SKILL.md 第 5 节>`、`prompt: 按任务书模板写的小探索任务——"梳理该项目顶层目录结构与各目录职责"，日志文件指定为 /Users/eric/HF-Distillation/.codex-agent/smoke-test.md`。

- [ ] **Step 2: 校验汇报与协议一致**

检查返回：五段标题一字不差；探索结论带证据位置；无 >10 行代码粘贴。不符 → 按协议容错用 `codex-reply` 纠正一次，并把偏差记录下来（说明 developer-instructions 需要加强措辞）。

- [ ] **Step 3: 补全 T1 落盘并校验**

Claude 将汇报写入 `<项目根>/.codex-agent/smoke-test.md`（文件头 + Round 1 + threadId）。
Run: `grep -n 'Round 1\|threadId' <项目根>/.codex-agent/smoke-test.md`
Expected: 两者均命中。

- [ ] **Step 4: 创建并校验 ACTIVE.md**

Claude 写入 `/Users/eric/HF-Distillation/.codex-agent/ACTIVE.md`：
`- smoke-test | 状态: active | threadId: <实际值> | 轮次: 1 | 下一步: thread 续接测试`
Run: `cat /Users/eric/HF-Distillation/.codex-agent/ACTIVE.md`
Expected: 上述格式一行，threadId 为实际值。

- [ ] **Step 5: 恢复演练 + thread 续接（模拟上下文丢失）**

模拟压缩/重置后的恢复路径：threadId **只从 ACTIVE.md 读取**（不用对话里的记忆），走恢复流程——读 ACTIVE.md → 读日志最后一轮 → `codex-reply` 追问一个只依赖上轮上下文的问题（如"你刚才结论里第 2 条的证据文件是哪个？"）。
Expected: codex 无需重新探索即可回答。这一步同时验证了会话保持与恢复流程两条链路。

- [ ] **Step 6: 收尾状态更新**

将 ACTIVE.md 中 smoke-test 行改为 `状态: done`。
Run: `grep 'smoke-test' /Users/eric/HF-Distillation/.codex-agent/ACTIVE.md`
Expected: 该行含 `状态: done`。

### Task 4: A/B 验收实测（可选，需用户提供真实任务）

**Interfaces:**
- Consumes: spec §9.4 的达标线（token 降幅 ≥80%、耗时 ≤1.3 倍、一次任务书达成率 ≥70%）。

- [ ] **Step 1: 用户挑一个真实中等任务，委托方式执行一遍，记录 `/cost`、耗时、轮数**
- [ ] **Step 2: 等价任务（或回滚后同任务）Claude 直做一遍，记录同口径数据**
- [ ] **Step 3: 对照达标线，任一不达标 → 优先加强任务书模板的「已知上下文」注入，修订 SKILL.md**
