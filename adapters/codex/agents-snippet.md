<!-- cc-remote:start -->
## 远程确认（cc-remote）

当任务需要用户决策/确认/选择方案时，先运行 `~/.cc-remote/bin/ccr status` 检查远程确认开关（dingtalk-notify）：

- **远程确认=on**（用户可能不在电脑前）：不要只在终端提问后停下——用户看不到。改用 Bash（timeout 600000ms）运行：
  `~/.cc-remote/bin/ccr ask "问题" --options "1=选项一,2=选项二"`
  stdout 即用户回复原文；`TIMEOUT` 则按安全默认继续并说明。小决策尽量合并为一次询问。
- **远程确认=off**（用户在电脑前）：直接文本提问即可。
<!-- cc-remote:end -->
