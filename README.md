# ccr — AI Coding 远程确认/通知系统

没盯屏幕/不在电脑前 → 开 **远程确认开关**（`ccr dingtalk-notify on`）：钉钉实时提问（机器人 @强提醒）→ 手机回复选项 → AI 继续干活。Claude Code 与 Codex 通用，macOS。

## 安装（4 步）

前置：已安装 dws CLI（DingTalk Workspace）并完成登录；电脑钉钉 + 手机钉钉同账号。

```bash
# 1. 克隆到 ~/.cc-remote（路径约定，hooks/skill 软链都指向这里）
git clone https://github.com/duan0710/ccr-skill.git ~/.cc-remote

# 2. 安装适配器: Claude hooks + 双平台 skill + Codex AGENTS.md + LaunchAgent 守护(全程幂等可重跑)
~/.cc-remote/bin/ccr install

# 3. 首次配置: 自动建专属钉钉群(或选已有群) + 引导配 webhook 机器人 + 往返自测
~/.cc-remote/bin/ccr setup

# 4. 打开远程确认开关
~/.cc-remote/bin/ccr dingtalk-notify on

# 可选: 加入 PATH, 之后直接用 ccr
echo 'export PATH="$PATH:$HOME/.cc-remote/bin"' >> ~/.zshrc
```

更新：`cd ~/.cc-remote && git pull && ccr install`（幂等，hooks/软链自动重建）。

## 日常使用

| 命令 | 作用 |
|---|---|
| `ccr dingtalk-notify on/off` | 远程确认开关：on 后需要确认 → 钉钉消息 → 手机回复 `token 1/2` → AI 继续 |
| `ccr status` / `ccr doctor` | 状态 / 全面体检 |
| `ccr daemon start\|stop\|log` | 守护进程管理 |
| `ccr inbox` | 查看未被路由的自由文本消息 |
| `ccr set inject on/off` | 引用「空闲等待」消息回复指令 → 是否直接键入会话终端 |
| `ccr uninstall` | 卸载适配器（保留 ~/.cc-remote 与配置） |

**场景**：离开电脑或没盯屏幕 `ccr dingtalk-notify on`；全程盯屏时 `off`（用本地提问）。

## 各平台能力

| 能力 | Claude Code | Codex |
|---|---|---|
| AI 主动提问 → 钉钉 → 手机回复 → 继续（`ccr ask` / askme 技能） | ✅ | ✅ |
| 权限审批弹窗远程放行/拒绝 | ✅ (PermissionRequest hook) | ❌ 无 hook，只能回电脑 |
| AI 空闲后手机下达自由文本指令 | ✅ 回执+inbox/注入 | ✅ daemon 注入(需开 terminal_inject) |

## 工作原理

```
Claude hooks: Notification(空闲通知/权限兜底) + PermissionRequest(远程确认放行) + UserPromptSubmit(状态注入)
Codex: skills/askme(同 Claude) + AGENTS.md 引导
共享: bin/ccr(CLI) + daemon.py(轮询群消息路由回复) + lib.sh + LaunchAgent 常驻
```

回复路由：钉钉消息带 4 位 token；`<token> 1` 精确路由、裸数字路由最早未决、引用=回复被引消息、`ccr` 白名单命令→本机执行+回执、自由文本→inbox/注入(均有机器人回执)。

## 已知限制与注意

- **macOS only**：LaunchAgent 守护 + Terminal.app 注入依赖 macOS
- **Mac 睡眠**会暂停守护与 hooks；离开时可让 Mac 不休眠（`caffeinate -d` 或系统设置）
- **远程确认开启时**权限提示在 hook 等待期间不显示在终端（显示「等待钉钉确认…」），期间可直接在**电脑端钉钉**回复，或等超时(默认8分钟)后本地提示弹出
- `ccr ask` 回复 `TIMEOUT`：AI 会按安全默认继续；重要决策建议选项里给"停止"
- 空闲指令直达终端：会话跑在 Terminal.app 或 tmux 里可注入；**IDEA 内置终端无法注入**（macOS 限制，落 inbox）
- dws 登录失效：`ccr doctor` 可检出；守护会桌面告警一次/小时
- 若你通过切换 `settings-*.json` 覆盖 settings.json, hooks 会丢失 → `ccr status` 红字提示, `ccr install --claude` 一键修复
- 钉钉通道两种：默认「本人身份发」（手机无提醒，仅电脑端可见）；推荐群里加自定义机器人（安全设置选**加签**）后 `ccr set webhook <access_token>` + `ccr set websecret <SEC密钥>` → 机器人加签直发并 @本人强提醒，外发不再依赖 dws 登录态

## 配置

`config.json`（首装从 `config.example.json` 初始化，勿提交）：

| 字段 | 说明 |
|---|---|
| `switch_b` | 远程确认开关（`ccr dingtalk-notify on/off`） |
| `dws_path` / `user_id` / `user_name` | dws CLI 路径与当前登录人（setup 自动填） |
| `group_id` / `group_title` | 专属确认群（setup 自动填） |
| `webhook_token` / `webhook_secret` | 群机器人加签直发通道（推荐，@强提醒） |
| `perm_wait_seconds` / `ask_wait_seconds` | 权限/询问等待秒数（默认 480 / 570） |
| `terminal_inject` | 空闲指令直达终端开关 |
