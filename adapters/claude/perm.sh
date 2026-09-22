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

# 终端"不再询问"选项的本体(permission_suggestions); 选 2 时原样回显为 updatedPermissions
suggestions=$(echo "$input" | jq -c '.permission_suggestions // []' 2>/dev/null)
n_sugg=$(echo "$suggestions" | jq 'length' 2>/dev/null)
[ -z "$n_sugg" ] && n_sugg=0
sugg_desc=""
auto_idx=2; deny_idx=3
if [ "$n_sugg" -gt 0 ]; then
  sugg_desc=$(echo "$suggestions" | jq -r '.[0].rules[]? | "\(.toolName)(\(.ruleContent // "*"))"' 2>/dev/null | head -3 | tr '\n' '，' | sed 's/，$//')
  auto_idx=3; deny_idx=4
fi

# shellcheck disable=SC2016
text="## 权限确认 ${token}$agent_note

**工具**: ${tool}　**项目**: ${proj}

\`\`\`
${preview}
\`\`\`

**选项**（与终端一致）：
- 1 ✅ 放行
"
[ "$n_sugg" -gt 0 ] && text="${text}- 2 ✅ 放行，且不再询问（${sugg_desc}）
"
text="${text}- ${auto_idx} ✅ 放行，并切 auto 模式（之后的权限提示自动处理）
- ${deny_idx} ❌ 拒绝（可附原因：\`${token} ${deny_idx} 原因\`）

💡 **引用本条**回复数字可免 token；不引用请带 token（如 \`${token} 1\`）"

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
[ -z "$deny_msg" ] && deny_msg="用户从钉钉远程拒绝"
# 槽位解释: 1=放行; 2=记住规则(有建议时)/否则auto; auto_idx=切auto; deny_idx/deny=拒绝
case "$choice" in
  1|y|yes|是|allow)
    ccr_send "已放行 $token" "\`${token}\` **已放行** ${tool}" >/dev/null 2>&1
    printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
    ;;
  2)
    if [ "$n_sugg" -gt 0 ]; then
      sugg0=$(printf '%s' "$suggestions" | jq -c '.[0]')
      ccr_send "已放行 $token" "\`${token}\` **已放行并记住规则**（${sugg_desc}）" >/dev/null 2>&1
      jq -cn --argjson s "$sugg0" '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"allow",updatedPermissions:[$s]}}}'
    else
      ccr_send "已放行 $token" "\`${token}\` **已放行并切换 auto 模式** ${tool}" >/dev/null 2>&1
      jq -cn '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"allow",updatedPermissions:[{type:"setMode",mode:"auto",destination:"session"}]}}}'
    fi ;;
  "$auto_idx")
    ccr_send "已放行 $token" "\`${token}\` **已放行并切换 auto 模式** ${tool}" >/dev/null 2>&1
    jq -cn '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"allow",updatedPermissions:[{type:"setMode",mode:"auto",destination:"session"}]}}}'
    ;;
  "$deny_idx"|deny|n|no|否)
    ccr_send "已拒绝 $token" "\`${token}\` **已拒绝** ${tool}：${deny_msg}" >/dev/null 2>&1
    jq -cn --arg m "用户从钉钉远程拒绝: $deny_msg" '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"deny",message:$m}}}'
    ;;
  *)
    # 有回复但无法识别槽位: 按拒绝处理并附用户原话; 无回复(超时): 本地提示照常弹出
    if [ -n "$reply" ]; then
      ccr_send "已拒绝 $token" "\`${token}\` 未识别回复，按**拒绝**处理：${raw_reply}" >/dev/null 2>&1
      jq -cn --arg m "用户从钉钉回复(未识别，按拒绝): ${raw_reply}" '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"deny",message:$m}}}'
    else
      ccr_send "已超时 $token" "\`${token}\` 等待超时，请回终端处理。" >/dev/null 2>&1
    fi ;;
esac
rm -f "$CCR_PENDING/$token.json" "$CCR_PENDING/$token.reply"
exit 0
