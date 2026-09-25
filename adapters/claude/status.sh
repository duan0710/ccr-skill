#!/bin/bash
# Claude Code UserPromptSubmit hook: ①每轮注入一行开关状态 ②写会话注册表(忙碌注入/无头兜底用)
# 总耗时须 <1s: 2 次 jq 读 + 1 次小文件写
input=$(cat)

CCR_DIR="${CCR_DIR:-$HOME/.cc-remote}"
line=$(jq -r '"[cc-remote] 远程确认(dingtalk-notify)=\(.switch_b)"' "$CCR_DIR/config.json" 2>/dev/null)
if [ "$(jq -r '.switch_b // false' "$CCR_DIR/config.json" 2>/dev/null)" = "true" ]; then
  line="$line。需要用户决策/确认时: 不要用 AskUserQuestion、不要只在终端提问, 改为运行 Bash(ccr路径 ~/.cc-remote/bin/ccr): ~/.cc-remote/bin/ccr ask \"问题\" --options \"1=选项一,2=选项二\" (timeout 600000), stdout 即用户回复; 回复 TIMEOUT 则按安全默认继续并说明。尽量把多个小决策合并为一次询问。"
fi
[ -n "$line" ] && echo "$line"


# ---- 会话注册表: session_id -> {tty, cwd, last_seen}, daemon 忙碌注入/无头兜底读 ----
if [ -n "$input" ]; then
  sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
  if [ -n "$sid" ] && [ "$sid" != "null" ]; then
    cwd_h=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
    cwd_h="${cwd_h//\"/}"
    ttys=$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')
    if [ -z "$ttys" ] || [ "$ttys" = "??" ]; then
      pp=$$
      for _ in 1 2 3 4 5; do
        pp=$(ps -o ppid= -p "$pp" 2>/dev/null | tr -d ' ')
        [ -z "$pp" ] && break
        ttys=$(ps -o tty= -p "$pp" 2>/dev/null | tr -d ' ')
        if [ -n "$ttys" ] && [ "$ttys" != "??" ]; then break; fi
      done
    fi
    # claude 进程 pid: 沿父链找 comm 含 claude 的祖先(daemon 注入前校验 pid 仍持有该 tty)
    pid_cur=$$
    claud_pid=""
    for _ in 1 2 3 4 5 6 7 8; do
      pid_cur=$(ps -o ppid= -p "$pid_cur" 2>/dev/null | tr -d ' ')
      [ -z "$pid_cur" ] || [ "$pid_cur" = "0" ] || [ "$pid_cur" = "1" ] && break
      case "$(ps -o comm= -p "$pid_cur" 2>/dev/null)" in
        *claude*) claud_pid="$pid_cur"; break ;;
      esac
    done
    # 会话别名(全生命周期稳定): 先确保已生成, 再 jq 合并刷新——别名绝不能被本轮重写丢掉
    salias=$(ccr_alias_for_session "$sid")
    mkdir -p "$CCR_DIR/sessions" 2>/dev/null
    f="$CCR_DIR/sessions/$sid.json"
    tmp=$(mktemp "$CCR_DIR/sessions/.s.XXXXXX" 2>/dev/null)
    if [ -n "$tmp" ] && jq --arg t "$ttys" --arg c "$cwd_h" --arg p "$claud_pid" --argjson ts "$(date +%s)" \
        '.tty=$t|.cwd=$c|.pid=$p|.last_seen=$ts' "$f" >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
      mv "$tmp" "$f" 2>/dev/null
    else
      [ -n "$tmp" ] && rm -f "$tmp"
      printf '{"session_id":"%s","alias":"%s","tty":"%s","cwd":"%s","pid":"%s","last_seen":%d}' \
        "$sid" "$salias" "$ttys" "$cwd_h" "$claud_pid" "$(date +%s)" \
        > "$f" 2>/dev/null
    fi
  fi
fi
exit 0

