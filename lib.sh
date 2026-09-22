#!/bin/bash
# cc-remote 公共库：配置读写、ticket、钉钉发送、桌面通知
# 被 bin/ccr 与 adapters/*/hooks 脚本 source

CCR_DIR="${CCR_DIR:-$HOME/.cc-remote}"
CCR_CONFIG="$CCR_DIR/config.json"
CCR_PENDING="$CCR_DIR/pending"
CCR_LOG_DIR="$CCR_DIR/logs"
mkdir -p "$CCR_PENDING" "$CCR_LOG_DIR" 2>/dev/null

# 用法: ccr_cfg '.switch_b // false'
ccr_cfg() {
  jq -r "$1" "$CCR_CONFIG" 2>/dev/null
}

# 用法: ccr_set '.switch_b' 'true'
ccr_set() {
  local tmp
  tmp=$(mktemp "$CCR_DIR/.config.XXXXXX") || return 1
  jq "$1 = \$v" --argjson v "$2" "$CCR_CONFIG" >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$CCR_CONFIG"
}

ccr_log() {
  echo "$(date '+%F %T') $*" >>"$CCR_LOG_DIR/ccr.log" 2>/dev/null
}

# 4 位小写字母数字 token
ccr_new_token() {
  local t
  while :; do
    t=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 4)
    [ ${#t} -eq 4 ] && { echo "$t"; return 0; }
  done
}

# 创建询问 ticket: ccr_mk_ticket <token> <kind> <extra-json-fields>
ccr_mk_ticket() {
  local token="$1" kind="$2" extra="${3:-null}"
  jq -n --arg t "$token" --arg k "$kind" --arg cwd "$PWD" --argjson extra "$extra" \
    '{token:$t, kind:$k, cwd:$cwd, created:(now|floor), extra:$extra}' \
    >"$CCR_PENDING/$token.json"
}

# webhook 机器人直发(加签): ccr_webhook_send <token> <标题> <markdown正文>
# 不依赖 dws 登录态; @本人触发手机强提醒(DingTalk 要求 at 字段 + 正文含 @userId)
ccr_webhook_send() {
  local token="$1" title="$2" text="$3" secret ts sign sign_enc body resp at_uid
  secret=$(ccr_cfg '.webhook_secret // ""')
  if [ -z "$secret" ] || [ "$secret" = "null" ]; then
    ccr_log "webhook send FAIL: .webhook_secret 未配置"
    return 1
  fi
  at_uid=$(ccr_cfg '.user_id // ""')
  [ "$at_uid" = "null" ] && at_uid=""
  if [ -n "$at_uid" ]; then
    text="${text}
@${at_uid}"
  fi
  # 加签: sign = urlencode(base64(hmac_sha256(secret, "{ts}\n{secret}")))
  ts=$(( $(date +%s) * 1000 ))
  sign=$(printf '%s\n%s' "$ts" "$secret" | /usr/bin/openssl dgst -sha256 -hmac "$secret" -binary | /usr/bin/base64 | tr -d '\n')
  sign_enc=$(printf '%s' "$sign" | jq -Rr @uri)
  body=$(jq -n --arg t "$title" --arg x "$text" --arg u "$at_uid" \
    '{msgtype:"markdown",markdown:{title:$t,text:$x},at:(if $u=="" then {} else {atUserIds:[$u]} end)}')
  resp=$(/usr/bin/curl -sS -m 10 -H 'Content-Type: application/json' -d "$body" \
    "https://oapi.dingtalk.com/robot/send?access_token=${token}&timestamp=${ts}&sign=${sign_enc}" 2>&1)
  if echo "$resp" | jq -e '.errcode == 0' >/dev/null 2>&1; then
    return 0
  fi
  ccr_log "webhook send FAIL resp=${resp:0:300}"
  return 1
}

# 发钉钉消息: ccr_send "标题" "markdown正文" [uuid]
# 按配置选择通道：group 模式优先 webhook 机器人(直发,见上)，未配置则降级为当前用户身份发群消息
# 正文统一加「【ccr】」标记行 —— daemon 靠它识别并跳过本系统发出的消息(用户身份模式下 sender 也是自己)
ccr_send() {
  local title="$1" text="$2" uuid="${3:-}"
  text="【ccr】
${text}"
  local mode dws gid token rc out
  dws=$(ccr_cfg '.dws_path')
  mode=$(ccr_cfg '.mode // "group"')

  local -a args
  if [ "$mode" = "bot_dm" ]; then
    local robot
    robot=$(ccr_cfg '.robot_code // ""')
    [ -z "$robot" ] || [ "$robot" = "null" ] && return 1
    args=(chat message send-by-bot --robot-code "$robot" --users "$(ccr_cfg '.user_id')")
  else
    gid=$(ccr_cfg '.group_id // ""')
    [ -z "$gid" ] && return 1
    token=$(ccr_cfg '.webhook_token // ""')
    if [ -n "$token" ] && [ "$token" != "null" ]; then
      ccr_webhook_send "$token" "$title" "$text"
      return $?
    else
      args=(chat message send --group "$gid")
    fi
  fi
  args+=(--title "$title" --text "$text")
  [ -n "$uuid" ] && [ "$mode" != "group" -o -z "$token" -o "$token" = "null" ] && args+=(--uuid "$uuid")
  args+=(--format json)

  out=$("$dws" "${args[@]}" 2>>"$CCR_LOG_DIR/dws.err") ; rc=$?
  if [ $rc -ne 0 ] || ! echo "$out" | jq -e '.success == true' >/dev/null 2>&1; then
    ccr_log "send FAIL rc=$rc out=${out:0:300}"
    return 1
  fi
  return 0
}

# 阻塞等待回复: ccr_wait_reply <token> <秒数>；成功时 stdout 输出回复 JSON
ccr_wait_reply() {
  local token="$1" timeout="$2"
  local deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -s "$CCR_PENDING/$token.reply" ]; then
      cat "$CCR_PENDING/$token.reply"
      return 0
    fi
    sleep 1
  done
  return 1
}

# 最近 N 秒内是否存在未决 ticket: ccr_has_recent_ticket <秒数> [kind]
ccr_has_recent_ticket() {
  local within="$1" kind="${2:-}" f now created k
  now=$(date +%s)
  for f in "$CCR_PENDING"/*.json; do
    [ -e "$f" ] || continue
    created=$(jq -r '.created // 0' "$f" 2>/dev/null)
    [ -z "$created" ] && continue
    if [ $((now - created)) -le "$within" ]; then
      if [ -n "$kind" ]; then
        k=$(jq -r '.kind // ""' "$f" 2>/dev/null)
        [ "$k" = "$kind" ] && return 0
      else
        return 0
      fi
    fi
  done
  return 1
}

# 清理过期 ticket（默认 30 分钟）
ccr_cleanup_tickets() {
  local max_age="${1:-1800}" f created
  for f in "$CCR_PENDING"/*.json "$CCR_PENDING"/*.reply; do
    [ -e "$f" ] || continue
    created=$(stat -f %m "$f" 2>/dev/null) || continue
    [ $(( $(date +%s) - created )) -gt "$max_age" ] && rm -f "$f"
  done
}
