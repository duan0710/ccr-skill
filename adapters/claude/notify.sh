#!/bin/bash
# Claude Code Notification hook (async=true, 无强制超时)
# 远程确认开: idle_prompt/agent_needs_input 发钉钉; permission_prompt 仅在无未决 perm ticket 时兜底
input=$(cat)
CCR_DIR="${CCR_DIR:-$HOME/.cc-remote}"
source "$CCR_DIR/lib.sh"

type=$(echo "$input" | jq -r '.notification_type // empty' 2>/dev/null)
cwd=$(echo "$input" | jq -r '.cwd // empty' 2>/dev/null)
proj="${cwd##*/}"
[ -z "$proj" ] && proj="Claude Code"

case "$type" in
  permission_prompt)
    # ---- 远程确认兜底: PermissionRequest hook 未接管的场景(沙箱网络请求等) ----
    if [ "$(ccr_cfg '.switch_b // false')" = "true" ]; then
      if ! ccr_has_recent_ticket 600 "perm"; then
        msg=$(echo "$input" | jq -r '.message // "需要权限确认"' 2>/dev/null)
        ccr_send "权限确认 · $proj" "## 本地权限提示

**项目**: ${proj}

${msg}

回到电脑后在终端确认。" >/dev/null 2>&1
      fi
    fi
    ;;
  idle_prompt|agent_needs_input)
    label="已空闲，等你的下一步输入"
    [ "$type" = "agent_needs_input" ] && label="后台 agent 等待输入"
    if [ "$(ccr_cfg '.switch_b // false')" = "true" ]; then
      # 本会话 tty(沿父链找到 claude 的控制终端): 引用回复的指令将直接键入
      ttys=$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')
      if [ -z "$ttys" ] || [ "$ttys" = "??" ]; then
        p=$$
        for _ in 1 2 3 4 5; do
          p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
          [ -z "$p" ] && break
          ttys=$(ps -o tty= -p "$p" 2>/dev/null | tr -d ' ')
          if [ -n "$ttys" ] && [ "$ttys" != "??" ]; then break; fi
        done
      fi
      token=$(ccr_new_token)
      ccr_mk_ticket "$token" "idle" "{\"proj\": \"$proj\", \"tty\": \"${ttys}\"}"
      ccr_send "空闲等待 · $proj" "## Claude $label ${token}

**项目**: ${proj}

**引用本条**回复指令 → 直接键入该会话终端（Terminal.app / tmux），跟亲手打字一样。" >/dev/null 2>&1
    fi
    ;;
esac
exit 0
