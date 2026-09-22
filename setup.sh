#!/bin/bash
# cc-remote 首次配置: 解析钉钉群 -> (可选)webhook机器人 -> 写配置 -> 往返自测
# 可交互运行, 也可带参: setup.sh --group-name "Claude远程确认" [--webhook-token XXX]
set -u
CCR_DIR="${CCR_DIR:-$HOME/.cc-remote}"
source "$CCR_DIR/lib.sh"

GROUP_NAME="${CCR_GROUP_NAME:-Claude远程确认}"
WEBHOOK_TOKEN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --group-name) GROUP_NAME="$2"; shift 2 ;;
    --webhook-token) WEBHOOK_TOKEN="$2"; shift 2 ;;
    *) shift ;;
  esac
done
DWS=$(ccr_cfg '.dws_path')
[ -z "$DWS" ] || [ "$DWS" = "null" ] || [ ! -x "$DWS" ] && DWS="$HOME/.local/bin/dws"

echo "== 1/4 检查 dws 登录 =="
if ! "$DWS" profile list --format json 2>/dev/null | jq -e '.profiles | length > 0' >/dev/null; then
  echo "!! dws 未登录，请先完成 dws 登录后再运行 ccr setup"
  exit 1
fi
# 自动记录 dws 路径与当前登录人(新装机 config 里是空的, 建群/at/防误路由都依赖)
ccr_set '.dws_path' "\"$DWS\"" 2>/dev/null
SELF_JSON=$("$DWS" contact +me --format json 2>/dev/null)
if [ -n "$SELF_JSON" ]; then
  _uid=$(echo "$SELF_JSON" | jq -r '.userId // empty')
  _uname=$(echo "$SELF_JSON" | jq -r '.name // empty')
  [ -n "$_uid" ] && ccr_set '.user_id' "\"$_uid\""
  [ -n "$_uname" ] && ccr_set '.user_name' "\"$_uname\""
  echo "OK (${_uname:-dws 已登录})"
else
  echo "OK (dws 已登录; 警告: contact +me 未返回, webhook @提醒可能不可用)"
fi

echo "== 2/4 定位专属群「${GROUP_NAME}」 =="
gid=""
out=$("$DWS" chat search --query "$GROUP_NAME" --limit 5 --format json 2>/dev/null)
count=$(echo "$out" | jq -r '.result.groups | length' 2>/dev/null || echo 0)
if [ "$count" = "0" ]; then
  echo "未找到该群，尝试自动创建(仅你一人)…"
  create=$("$DWS" chat group create --name "$GROUP_NAME" --users "$(ccr_cfg '.user_id')" --format json 2>&1)
  cid=$(echo "$create" | jq -r '.result.openConversationId // .result.conversationId // empty' 2>/dev/null)
  if [ -n "$cid" ]; then
    gid="$cid"
    echo "已创建群 $GROUP_NAME ($gid)"
  else
    echo "自动创建失败: $(echo "$create" | head -c 200)"
    echo "请手动操作: 电脑钉钉 -> 建群「${GROUP_NAME}」(可先拉任意同事再移出) -> 完成后重新运行 ccr setup"
    exit 1
  fi
else
  if [ "$count" = "1" ] || [ -n "$WEBHOOK_TOKEN" ]; then
    idx=0
  else
    echo "$out" | jq -r '.result.groups[] | "\(.title) -> \(.openConversationId)"'
    printf "多个候选, 输入序号(从0开始): "; read -r idx
  fi
  gid=$(echo "$out" | jq -r ".result.groups[$idx].openConversationId" 2>/dev/null)
  [ -z "$gid" ] || [ "$gid" = "null" ] && { echo "!! 群 ID 解析失败"; exit 1; }
  echo "已选中: $(echo "$out" | jq -r ".result.groups[$idx].title") ($gid)"
fi
ccr_set '.group_id' "\"$gid\""
ccr_set '.group_title' "\"$GROUP_NAME\""

echo "== 3/4 webhook 机器人(可选, 跳过则以你本人身份发通知) =="
if [ -n "$WEBHOOK_TOKEN" ]; then
  ccr_set '.webhook_token' "\"$WEBHOOK_TOKEN\""
  echo "已写入 webhook token"
elif [ -t 0 ]; then
  printf "粘贴 Webhook access_token(直接回车跳过): "
  read -r tok
  if [ -n "$tok" ]; then
    ccr_set '.webhook_token' "\"$tok\""
    echo "已写入 webhook token"
  else
    echo "跳过 -> 通知将以「%s」身份发进群" "$(ccr_cfg '.user_name')"
  fi
  if [ -n "$(ccr_cfg '.webhook_token // ""')" ] && [ "$(ccr_cfg '.webhook_token // ""')" != "null" ] && [ -z "$(ccr_cfg '.webhook_secret // ""')" ]; then
    printf "粘贴机器人加签密钥 SEC(群机器人安全设置页, 直接回车跳过): "
    read -r sec
    [ -n "$sec" ] && ccr_set '.webhook_secret' "\"$sec\"" && echo "已写入加签密钥"
  fi
fi

# 非交互模式只给了 token 没给 secret 时提示
if [ -n "$(ccr_cfg '.webhook_token // ""')" ] && [ "$(ccr_cfg '.webhook_token // ""')" != "null" ] \
   && { [ -z "$(ccr_cfg '.webhook_secret // ""')" ] || [ "$(ccr_cfg '.webhook_secret // ""')" = "null" ]; }; then
  echo "提示: 未配置加签密钥, 可稍后 ccr set websecret <SEC> 补上(机器人发送模式必需)"
fi

echo "== 4/4 发送测试消息 =="
if ccr_send "cc-remote 配置成功" "## Claude/Codex 远程确认已就绪

**群**: ${GROUP_NAME}

后续 AI 需要确认时会发到这里，回复 \`token 数字\` 即可。"; then
  echo "测试消息已发送到群，请检查钉钉。"
else
  echo "!! 测试消息发送失败，检查 logs/dws.err"
  exit 1
fi
"$CCR_DIR/bin/ccr" daemon ensure
echo
echo "完成。验证往返: ccr test   开关: ccr dingtalk-notify on"
