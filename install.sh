#!/bin/bash
# codex-agent skill 安装器（幂等，可重复执行）
# 用法: bash install.sh
# 平台: macOS / Linux / WSL / Git Bash（原生 Windows PowerShell 不支持——请在 WSL 内安装）
set -u
SRC="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
OK=0; WARN=0

say()  { printf '%s\n' "$*"; }
pass() { say "  [OK]   $*"; }
warn() { say "  [WARN] $*"; WARN=$((WARN+1)); }

say "=== 1/4 前置检查 ==="
if command -v codex >/dev/null 2>&1; then
  pass "codex CLI: $(codex --version 2>/dev/null | head -1)"
else
  warn "未找到 codex CLI —— 请先安装并登录（npm i -g @openai/codex && codex login）"
fi
if command -v claude >/dev/null 2>&1; then pass "Claude Code CLI 已安装"; else warn "未找到 claude CLI"; fi
PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] && pass "python: $PY" || warn "未找到 python/python3（verify.sh 需要）"
case "$(uname -s 2>/dev/null)" in
  Darwin) pass "平台 macOS（全量验证平台）";;
  Linux)  pass "平台 Linux/WSL（兼容；首次使用建议跑一次 T1 冒烟）";;
  MINGW*|MSYS*|CYGWIN*) warn "Git Bash on Windows：codex 沙箱为实验性——协议 §3.6 要求沙箱不等价时改用 approval on-request";;
  *) warn "未知平台 $(uname -s)";;
esac

say "=== 2/4 安装 skill 文件 ==="
TARGET="$CLAUDE_DIR/skills/codex-agent"
if [ -f "$SRC/SKILL.md" ]; then SKILL_SRC="$SRC"; else SKILL_SRC="$SRC/codex-agent"; fi   # 兼容仓库直跑与 tar 包两种布局
if [ "$SKILL_SRC" = "$TARGET" ]; then
  pass "已在目标位置（git clone 到位或本机维护模式），跳过复制"
else
  mkdir -p "$CLAUDE_DIR/skills"
  cp -R "$SKILL_SRC" "$TARGET"
  pass "已安装 $TARGET/"
fi
chmod +x "$TARGET/scripts/"*.sh
pass "脚本执行权限已设置"

say "=== 3/4 CLAUDE.md 触发规则 ==="
if grep -q '## Codex 委托' "$CLAUDE_DIR/CLAUDE.md" 2>/dev/null; then
  pass "触发规则已存在，跳过（幂等）"
else
  mkdir -p "$CLAUDE_DIR"
  cat >> "$CLAUDE_DIR/CLAUDE.md" <<'RULE'

## Codex 委托
凡涉及代码探索或修改的任务（需读 ≥3 个文件、跨文件改动、或单文件改动 >10 行），先调用 codex-agent skill，按其路由表委托给 codex MCP 执行。仅微编辑（单文件、位置已知、≤10 行）由 Claude 直接完成。
开始代码工作前，若项目根存在 .codex-agent/ACTIVE.md，先读取并恢复未完结的委托工作流（上下文压缩、/clear、会话切换后同样适用）。
RULE
  pass "已追加触发规则到 $CLAUDE_DIR/CLAUDE.md"
fi

say "=== 4/4 MCP 注册检查 ==="
if grep -q '"codex"' "$HOME/.claude.json" 2>/dev/null; then
  pass "codex MCP server 已注册"
else
  warn "codex 未注册为 MCP server。执行：claude mcp add --scope user codex -- codex mcp-server"
fi

say ""
if [ "$WARN" -eq 0 ]; then
  say "安装完成，全部检查通过。新开 Claude Code 会话即生效。"
else
  say "安装完成，但有 $WARN 项 WARN 需要处理（见上）。"
fi
say "首次使用提示：新项目首次委托前，在 codex 里信任该目录（codex 内运行一次即会询问），"
say "并让 skill 顺带生成该项目的 .codex-agent/PROJECT-MAP.md（首次任务自动发生）。"
