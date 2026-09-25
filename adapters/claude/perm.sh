#!/bin/bash
# Claude Code PermissionRequest hook (同步, handler timeout 510s)
# B开: 发钉钉 -> 阻塞等回复 -> decision allow/deny; 超时/故障 -> exit 0 本地提示照常弹出
input=$(cat)
CCR_DIR="${CCR_DIR:-$HOME/.cc-remote}"
source "$CCR_DIR/lib.sh"

# B 关或通道未配置: 立即放行给本地权限提示
[ "$(ccr_cfg '.switch_b // false')" = "true" ] || exit 0
gid=$(ccr_cfg '.group_id // ""'); robot=$(ccr_cfg '.robot_code // ""')
{ [ -z "$gid" ] || [ "$gid" = "null" ]; } && { [ -z "$robot" ] || [ "$robot" = "null" ]; } && exit 0

tool=$(echo "$input" | jq -r '.tool_name // "Tool"' 2>/dev/null)
cwd=$(echo "$input" | jq -r '.cwd // empty' 2>/dev/null)
session=$(echo "$input" | jq -r '.session_id // empty' 2>/dev/null)
agent_note=""
[ -n "$(echo "$input" | jq -r '.agent_id // empty' 2>/dev/null)" ] && agent_note=" *(subagent)*"
proj="${cwd##*/}"; [ -z "$proj" ] && proj="claude"

# 命令/文件预览: 优先常见字段, 否则整个 tool_input 截断
preview=$(echo "$input" | jq -r '.tool_input.command // .tool_input.file_path // .tool_input.url // .tool_input.notebook_path // empty' 2>/dev/null)
if [ -z "$preview" ] || [ "$preview" = "null" ]; then
  preview=$(echo "$input" | jq -c '.tool_input // {}' 2>/dev/null | head -c 300)
fi
preview=$(printf '%s' "$preview" | head -c 300)

token=$(ccr_new_token)
ccr_mk_ticket "$token" "perm" "{\"tool\": \"$tool\", \"session_id\": \"$session\"}"

# 终端权限弹窗选项构成: 1=Yes + 每条 permission_suggestions 一项 + No, 卡片按此动态生成
# 实测建议类型: setMode(mode=acceptEdits/auto) / addDirectories([目录]); 旧版 schema 为 rules[{toolName,ruleContent}]
# 最多取 2 条: 回复通道(钉钉/ccr reply)的槽位数字只支持 1-4
suggestions=$(echo "$input" | jq -c '[.permission_suggestions[]?][0:2]' 2>/dev/null)
n_sugg=$(echo "$suggestions" | jq 'length' 2>/dev/null)
[ -z "$n_sugg" ] && n_sugg=0
deny_idx=$((n_sugg + 2))

# 单条建议 -> 选项行描述(以"放行,"开头拼接); 未知类型兜底, 不再出现空括号
sugg_desc() { # $1=suggestion JSON
  local s="$1" t rules
  t=$(echo "$s" | jq -r '.type // ""')
  case "$t" in
    setMode)
      echo "并切 $(echo "$s" | jq -r '.mode // "auto"') 模式（之后的权限提示自动处理）" ;;
    addDirectories)
      echo "且本会话不再询问 $(echo "$s" | jq -r '(.directories // []) | join("、")') 下的操作" ;;
    *)
      rules=$(echo "$s" | jq -r '.rules[]? | "\(.toolName)(\(.ruleContent // "*"))"' 2>/dev/null | head -3 | tr '\n' '，' | sed 's/，$//')
      if [ -n "$rules" ]; then echo "且不再询问（${rules}）"; else echo "且记住建议规则（${t:-未类型}）"; fi ;;
  esac
}

# 选项行: 1=放行, 2..=放行+对应建议(按 permission_suggestions 顺序回显), 末位=拒绝
opts="- 1 ✅ 放行
"
i=0
while [ "$i" -lt "$n_sugg" ]; do
  opts="${opts}- $((i+2)) ✅ 放行，$(sugg_desc "$(echo "$suggestions" | jq -c ".[$i]")")
"
  i=$((i+1))
done
opts="${opts}- ${deny_idx} ❌ 拒绝（可附原因：\`${token} ${deny_idx} 原因\`）"

# shellcheck disable=SC2016
text="## 权限确认 ${token}$agent_note

**工具**: ${tool}　**项目**: ${proj}

\`\`\`
${preview}
\`\`\`

**选项**（按序对应终端弹窗）：
${opts}

💡 超时前在电脑旁可直接放行: 终端运行 \`ccr reply ${token} 1\`
**引用本条**回复数字可免 token；不引用请带 token（如 \`${token} 1\`）"

# 本机桌面通知: 权限远程等待期间终端不显示提示, 屏幕上同步可见(引用/钉钉回复皆可)
ccr_local_notify "权限确认 $token" "$tool · $proj — 钉钉回复数字放行, 或等超时本地弹窗"

ccr_set_title "⏳ccr权限 $token · $tool"
if ! ccr_send "权限确认 $token · $tool · $proj" "$text" "$token"; then
  rm -f "$CCR_PENDING/$token.json"
  exit 0   # 钉钉故障绝不卡权限流
fi

wait_s=$(ccr_cfg '.perm_wait_seconds // 480')
deadline=$(( $(date +%s) + wait_s ))
reply=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ -s "$CCR_PENDING/$token.reply" ]; then reply=$(cat "$CCR_PENDING/$token.reply"); break; fi
  sleep 1
done

choice=$(echo "$reply" | jq -r '.choice // empty' 2>/dev/null)
raw_reply=$(echo "$reply" | jq -r '.raw // empty' 2>/dev/null)
deny_msg=$(printf '%s' "$raw_reply" | sed -E 's/^[1-4][[:space:]]*//;s/^[[:space:]]+//')
[ -z "$deny_msg" ] && deny_msg="未附原因"
# 槽位解释: 1=放行; 2..deny_idx-1=放行并回显对应建议(echo permission_suggestions, 官方支持); deny_idx/deny=拒绝
case "$choice" in
  1|y|yes|是|allow)
    ccr_send "已放行 $token" "\`${token}\` **已放行** ${tool}" >/dev/null 2>&1
    printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
    ;;
  "$deny_idx"|deny|n|no|否)
    ccr_send "已拒绝 $token" "\`${token}\` **已拒绝** ${tool}：${deny_msg}" >/dev/null 2>&1
    jq -cn --arg m "用户从钉钉远程拒绝: $deny_msg" '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"deny",message:$m}}}'
    ;;
  *)
    if [ "$choice" -ge 2 ] 2>/dev/null && [ "$choice" -lt "$deny_idx" ] 2>/dev/null; then
      sugg0=$(echo "$suggestions" | jq -c ".[$((choice-2))]")
      ccr_send "已放行 $token" "\`${token}\` **已放行**（$(sugg_desc "$sugg0")）${tool}" >/dev/null 2>&1
      jq -cn --argjson s "$sugg0" '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"allow",updatedPermissions:[$s]}}}'
    elif [ -n "$reply" ]; then
      # 有回复但无法识别槽位: 按拒绝处理并附用户原话; 无回复(超时): 本地提示照常弹出
      ccr_send "已拒绝 $token" "\`${token}\` 未识别回复，按**拒绝**处理：${raw_reply}" >/dev/null 2>&1
      jq -cn --arg m "用户从钉钉回复(未识别，按拒绝): ${raw_reply}" '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"deny",message:$m}}}'
    else
      ccr_send "已超时 $token" "\`${token}\` 等待超时，请回终端处理。" >/dev/null 2>&1
    fi ;;
esac
rm -f "$CCR_PENDING/$token.json" "$CCR_PENDING/$token.reply"
ccr_set_title ""
exit 0
