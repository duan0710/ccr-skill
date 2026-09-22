#!/bin/bash
# Claude Code UserPromptSubmit hook: 每轮注入一行开关状态(纯文本, 不得以{开头)
# 必须 <1s 完成: 只做一次 jq 读
cat >/dev/null  # 丢弃 stdin JSON

CCR_DIR="${CCR_DIR:-$HOME/.cc-remote}"
line=$(jq -r '"[cc-remote] 远程确认(dingtalk-notify)=\(.switch_b)"' "$CCR_DIR/config.json" 2>/dev/null)
if [ "$(jq -r '.switch_b // false' "$CCR_DIR/config.json" 2>/dev/null)" = "true" ]; then
  line="$line。需要用户决策/确认时: 不要用 AskUserQuestion、不要只在终端提问, 改为运行 Bash(ccr路径 ~/.cc-remote/bin/ccr): ~/.cc-remote/bin/ccr ask \"问题\" --options \"1=选项一,2=选项二\" (timeout 600000), stdout 即用户回复; 回复 TIMEOUT 则按安全默认继续并说明。尽量把多个小决策合并为一次询问。"
fi
[ -n "$line" ] && echo "$line"
exit 0
