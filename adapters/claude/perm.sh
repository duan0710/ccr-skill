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
# 会话别名(稳定标识): 卡片上区分会话, 也是远程定向指令的地址
salias=$(ccr_alias_for_session "$session")

# 命令/文件预览: 优先常见字段, 否则整个 tool_input 截断
preview=$(echo "$input" | jq -r '.tool_input.command // .tool_input.file_path // .tool_input.url // .tool_input.notebook_path // empty' 2>/dev/null)
if [ -z "$preview" ] || [ "$preview" = "null" ]; then
  preview=$(echo "$input" | jq -c '.tool_input // {}' 2>/dev/null | head -c 300)
fi
preview=$(printf '%s' "$preview" | head -c 300)

token=$(ccr_new_token)
ccr_mk_ticket "$token" "perm" "{\"tool\": \"$tool\", \"session_id\": \"$session\"}"

# 终端权限弹窗选项构成: 1=Yes + 规则类建议各一项 + (Bash提示的 auto 项) + No
# - 规则类建议(addRules/addDirectories/未知)按序回显; setMode 类收进模式槽
# - auto 项无建议对应体(官方文档: Bash 提示在 default/manual/acceptEdits 下额外加"切 auto",
#   直接改模式不经 permission update), hook 入参看不到 -> 按条件合成 {type:setMode,mode:auto}
# - 槽位总数(含1放行/末位拒绝)<=4: 两条规则建议与模式槽并存时裁掉第二条规则建议
rule_suggs=$(echo "$input" | jq -c '[.permission_suggestions[]? | select(.type != "setMode")][0:2]' 2>/dev/null)
mode_sugg=$(echo "$input" | jq -c '([.permission_suggestions[]? | select(.type == "setMode")][0] // "")' 2>/dev/null)
perm_mode=$(echo "$input" | jq -r '.permission_mode // "default"' 2>/dev/null)
[ -z "$rule_suggs" ] && rule_suggs="[]"

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

# 组装中间槽位(描述+载荷): 规则建议优先, 模式槽殿后(与终端顺序一致)
slot_descs=(); slot_payloads=()
n_rule=$(echo "$rule_suggs" | jq 'length' 2>/dev/null); [ -z "$n_rule" ] && n_rule=0
mode_desc=""; mode_payload=""
case "$mode_sugg" in *[![:space:]]*) mode_desc="放行，$(sugg_desc "$mode_sugg")"; mode_payload="$mode_sugg" ;; esac
if [ "$tool" = "Bash" ]; then
  case "$perm_mode" in
    default|manual|acceptEdits)
      # 终端会显示"切 auto"且无建议对应体 -> 合成槽位, 优先于 setMode 建议(语义重复)
      mode_desc="放行，并切 auto 模式（之后的权限提示自动处理）"
      mode_payload='{"type":"setMode","mode":"auto","destination":"session"}' ;;
  esac
fi
[ "$n_rule" -gt 1 ] && [ -n "$mode_desc" ] && n_rule=1   # 裁剪保总槽位<=4
i=0
while [ "$i" -lt "$n_rule" ]; do
  s=$(echo "$rule_suggs" | jq -c ".[$i]")
  slot_descs+=("放行，$(sugg_desc "$s")"); slot_payloads+=("$s")
  i=$((i+1))
done
[ -n "$mode_desc" ] && { slot_descs+=("$mode_desc"); slot_payloads+=("$mode_payload"); }
deny_idx=$(( ${#slot_descs[@]} + 2 ))

# 选项行: 1=放行, 2..=放行+建议/模式槽, 末位=拒绝
opts="- 1 ✅ 放行
"
i=0
while [ "$i" -lt "${#slot_descs[@]}" ]; do
  opts="${opts}- $((i+2)) ✅ ${slot_descs[$i]}
"
  i=$((i+1))
done
opts="${opts}- ${deny_idx} ❌ 拒绝（可附原因：\`${token} ${deny_idx} 原因\`）"

# shellcheck disable=SC2016
text="## 权限确认 ${token}$agent_note

**工具**: ${tool}　**项目**: ${proj}${salias:+　**会话**: ${salias}}

\`\`\`
${preview}
\`\`\`

**选项**（按序对应终端弹窗）：
${opts}

💡 超时前在电脑旁可直接放行: 终端运行 \`ccr reply ${token} 1\`
**引用本条**回复数字可免 token；不引用请带 token（如 \`${token} 1\`）"

# 本机桌面通知: 权限远程等待期间终端不显示提示, 屏幕上同步可见(引用/钉钉回复皆可)
ccr_local_notify "权限确认 $token" "$tool · $proj${salias:+($salias)} — 钉钉回复数字放行, 或等超时本地弹窗"

ccr_set_title "⏳ccr权限 ${salias:+$salias·}$token · $tool"
if ! ccr_send "权限确认 $token · $tool · $proj${salias:+·$salias}" "$text" "$token"; then
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
      pay="${slot_payloads[$((choice-2))]}"
      ccr_send "已放行 $token" "\`${token}\` **已放行** ${slot_descs[$((choice-2))]}${tool:+ · $tool}" >/dev/null 2>&1
      jq -cn --argjson s "$pay" '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"allow",updatedPermissions:[$s]}}}'
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
