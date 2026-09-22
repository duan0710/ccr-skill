#!/bin/bash
# ccr test: 端到端往返自测 —— 发一条带 token 的询问到钉钉群, 等用户回复, 验证路由落盘
set -u
CCR_DIR="${CCR_DIR:-$HOME/.cc-remote}"
source "$CCR_DIR/lib.sh"

if [ "$(ccr_cfg '.switch_b // false')" != "true" ]; then
  echo "需要先开远程确认: ccr dingtalk-notify on"; exit 1
fi
"$CCR_DIR/bin/ccr" daemon ensure

token=$(ccr_new_token)
proj=$(basename "$PWD")
ccr_mk_ticket "$token" "ask" '{"question": "ccr test"}'
# shellcheck disable=SC2016
if ! ccr_send "自测 $token · $proj" "## 待确认 ${token}

**这是 cc-remote 往返自测**

回复 \`${token} ok\` 完成验证"; then
  rm -f "$CCR_PENDING/$token.json"; echo "发送失败(见 logs/dws.err)"; exit 1
fi
echo "已发送, 请在钉钉群里回复: $token ok   (等待 120s…)"
if reply=$(ccr_wait_reply "$token" 120); then
  echo "✓ 往返成功: $(echo "$reply" | jq -r '.raw')"
  rm -f "$CCR_PENDING/$token.json" "$CCR_PENDING/$token.reply"
  exit 0
else
  rm -f "$CCR_PENDING/$token.json"
  echo "✗ 120s 未收到回复。排查: ccr daemon log / ccr doctor"
  exit 1
fi
