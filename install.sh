#!/bin/bash
# cc-remote 安装器: Claude Code hooks + 双平台 skill + Codex AGENTS.md + LaunchAgent
# 用法: install.sh [--claude|--codex|--all]   install.sh --uninstall [--claude|--codex|--all]
set -u
CCR_DIR="${CCR_DIR:-$HOME/.cc-remote}"
LABEL="cc-remote.daemon"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LAUNCH_PLIST_DST="$LAUNCH_AGENTS_DIR/${LABEL}.plist"
# 兼容迁移: 旧版个人化 label, 安装/卸载时一并清理
LEGACY_LABELS=("com.duan.cc-remote.daemon")

TARGET="all"; UNINSTALL=0
for a in "$@"; do
  case "$a" in
    --claude) TARGET="claude" ;;
    --codex) TARGET="codex" ;;
    --all) TARGET="all" ;;
    --uninstall) UNINSTALL=1 ;;
  esac
done
want() { [ "$TARGET" = "all" ] || [ "$TARGET" = "$1" ]; }

# ---------- Claude: hooks 注入(幂等: 先剔除本系统旧条目再追加) ----------
hooks_json() {
  jq -cn --arg ccr "$CCR_DIR" \
    '{Notification: [{matcher: "permission_prompt|idle_prompt|agent_needs_input",
       hooks: [{type: "command", command: ($ccr+"/adapters/claude/notify.sh"), async: true}]}],
     PermissionRequest: [{hooks: [{type: "command", command: ($ccr+"/adapters/claude/perm.sh"),
       timeout: 510, statusMessage: "cc-remote: 等待钉钉确认…"}]}],
     UserPromptSubmit: [{hooks: [{type: "command", command: ($ccr+"/adapters/claude/status.sh"), timeout: 5}]}]}'
}

patch_claude_settings() {
  local f="$1"
  [ -f "$f" ] || return 0
  local tmp; tmp=$(mktemp) || return 1
  if jq --argjson h "$(hooks_json)" '
    def strip_ours: map(select(((.hooks // []) | map((.command // "") | contains("cc-remote")) | any) | not));
    .hooks = (.hooks // {}) |
    .hooks.Notification      = (((.hooks.Notification // [])      | strip_ours) + $h.Notification) |
    .hooks.PermissionRequest = (((.hooks.PermissionRequest // []) | strip_ours) + $h.PermissionRequest) |
    .hooks.UserPromptSubmit  = (((.hooks.UserPromptSubmit // [])  | strip_ours) + $h.UserPromptSubmit)
  ' "$f" >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$f"; echo "  hooks -> $f"
  else
    rm -f "$tmp"; echo "  !! $f 合并失败(跳过)"
  fi
}

strip_claude_settings() {
  local f="$1"
  [ -f "$f" ] || return 0
  local tmp; tmp=$(mktemp) || return 1
  if jq '
    def strip_ours: map(select(((.hooks // []) | map((.command // "") | contains("cc-remote")) | any) | not));
    if has("hooks") and (.hooks | type) == "object" then
      .hooks |= with_entries(.value |= (if type == "array" then strip_ours else . end))
             | .hooks |= with_entries(select(.value | length > 0))
             | (if (.hooks | length) == 0 then del(.hooks) else . end)
    else . end
  ' "$f" >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$f"; echo "  hooks 已移除 <- $f"
  else
    rm -f "$tmp"; echo "  !! $f 清理失败"
  fi
}

install_claude() {
  echo "[claude]"
  local dest="$HOME/.claude/skills/askme"
  if [ -L "$dest" ] || [ -e "$dest" ]; then rm -rf "$dest"; fi
  ln -s "$CCR_DIR/skill" "$dest" && echo "  skill -> $dest"
  for f in "$HOME/.claude/settings.json" "$HOME/.claude"/settings-*.json; do
    [ -f "$f" ] || continue
    if [ "$UNINSTALL" -eq 1 ]; then strip_claude_settings "$f"; else patch_claude_settings "$f"; fi
  done
  if [ "$UNINSTALL" -eq 0 ]; then
    echo "  注意: 若你通过切换 settings-*.json 覆盖 settings.json, hooks 会丢失 -> 重新运行 ccr install --claude"
  fi
}

install_codex() {
  echo "[codex]"
  local codex_home="$HOME/.codex"
  [ -d "$codex_home" ] || { echo "  未检测到 $codex_home, 跳过"; return 0; }
  local dest="$codex_home/skills/askme"
  if [ "$UNINSTALL" -eq 1 ]; then
    [ -L "$dest" ] && rm "$dest" && echo "  skill 已移除 <- $dest"
    if [ -f "$codex_home/AGENTS.md" ] && grep -q "cc-remote:start" "$codex_home/AGENTS.md"; then
      sed -i '' '/cc-remote:start/,/cc-remote:end/d' "$codex_home/AGENTS.md"
      echo "  AGENTS.md 段已移除"
    fi
    return 0
  fi
  mkdir -p "$codex_home/skills"
  if [ -L "$dest" ] || [ -e "$dest" ]; then rm -rf "$dest"; fi
  ln -s "$CCR_DIR/skill" "$dest" && echo "  skill -> $dest"
  if ! grep -q "cc-remote:start" "$codex_home/AGENTS.md" 2>/dev/null; then
    cat "$CCR_DIR/adapters/codex/agents-snippet.md" >>"$codex_home/AGENTS.md"
    echo "  AGENTS.md <- 追加引导段"
  fi
}

# ---------- LaunchAgent plist 按真实 $HOME 现场生成(不依赖静态模板) ----------
gen_plist() {
  mkdir -p "$LAUNCH_AGENTS_DIR" "$CCR_DIR/logs"
  cat >"$LAUNCH_PLIST_DST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>${CCR_DIR}/daemon.py</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>15</integer>
  <key>ProcessType</key><string>Background</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>${HOME}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key><string>${HOME}</string>
  </dict>
  <key>StandardOutPath</key><string>${CCR_DIR}/logs/daemon-stdout.log</string>
  <key>StandardErrorPath</key><string>${CCR_DIR}/logs/daemon-stderr.log</string>
</dict>
</plist>
PLIST
}

bootout_label() {
  launchctl bootout "gui/$(id -u)/$1" 2>/dev/null || true
  rm -f "$LAUNCH_AGENTS_DIR/$1.plist"
}

install_daemon() {
  # 清理旧版 label 的 LaunchAgent(幂等)
  for l in "${LEGACY_LABELS[@]}"; do
    [ "$l" = "$LABEL" ] && continue
    if [ -f "$LAUNCH_AGENTS_DIR/$l.plist" ]; then
      bootout_label "$l" && echo "[daemon] 已清理旧版 LaunchAgent: $l"
    fi
  done
  if [ "$UNINSTALL" -eq 1 ]; then
    bootout_label "$LABEL" && echo "[daemon] LaunchAgent 已移除"
    pkill -f "daemon.py" 2>/dev/null
    return 0
  fi
  chmod +x "$CCR_DIR/bin/ccr" "$CCR_DIR/daemon.py" "$CCR_DIR/adapters/claude/"*.sh
  gen_plist
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$LAUNCH_PLIST_DST" 2>/dev/null \
    || launchctl load -w "$LAUNCH_PLIST_DST" 2>/dev/null
  echo "[daemon] LaunchAgent 已加载 (${LABEL})"
}

if [ "$UNINSTALL" -eq 1 ]; then
  echo "== 卸载 cc-remote 适配器 (保留 ~/.cc-remote 与配置) =="
  want claude && install_claude
  want codex && install_codex
  install_daemon
  echo "完成。如需彻底删除: rm -rf ~/.cc-remote"
  exit 0
fi

echo "== 安装 cc-remote =="
chmod +x "$CCR_DIR/bin/ccr" "$CCR_DIR/daemon.py" "$CCR_DIR/adapters/claude/"*.sh 2>/dev/null
# 首装兜底: config.json 不存在时从模板复制(ccr_set 对缺失文件会静默失败)
if [ ! -f "$CCR_DIR/config.json" ] && [ -f "$CCR_DIR/config.example.json" ]; then
  cp "$CCR_DIR/config.example.json" "$CCR_DIR/config.json"
  echo "  config.json <- 从模板初始化"
fi
want claude && install_claude
want codex && install_codex
install_daemon
echo
echo "下一步: ~/.cc-remote/bin/ccr setup   # 配置钉钉群并自测"
echo "建议把 ccr 加入 PATH: echo 'export PATH=\"\$PATH:\$HOME/.cc-remote/bin\"' >> ~/.zshrc"
