#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cc-remote daemon: 轮询钉钉群消息, 路由用户回复到 pending/<token>.reply

- `<token> 1|2|y|n|是|否`  -> 精确路由到对应 ticket
- 裸 `1|2|y|n|是|否`       -> 路由到最早的未决 ticket
- 其余自由文本             -> terminal_inject 开启时注入 Terminal.app(best-effort), 同时落 inbox
- 幂等: state.json 记录游标与已见消息 ID
"""
import base64
import hashlib
import hmac
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime
from urllib.parse import quote
from urllib.request import Request, urlopen

CCR = os.path.expanduser("~/.cc-remote")
CFG_PATH = os.path.join(CCR, "config.json")
STATE_PATH = os.path.join(CCR, "state.json")
PENDING = os.path.join(CCR, "pending")
INBOX = os.path.join(CCR, "logs", "inbox.txt")
DAEMON_LOG = os.path.join(CCR, "logs", "daemon.log")

TOKEN_RE = re.compile(r"^([a-z0-9]{4})[\s,:，:：]*(.*)$")
BARE_CHOICE_RE = re.compile(r"^(1|2|3|4|y|n|yes|no|是|否|allow|deny)$", re.IGNORECASE)
# 本系统发出的消息正文首行为「【ccr】」标记(见 lib.sh ccr_send)
SELF_MARKER = "【ccr】"
# choice: 1-4=消息里的选项槽位(perm.sh 按自身选项构成解释), deny=拒绝语义
CHOICE_MAP = {"1": "1", "2": "2", "3": "3", "4": "4",
              "y": "1", "yes": "1", "是": "1", "allow": "1", "放行": "1", "同意": "1", "ok": "1",
              "n": "deny", "no": "deny", "否": "deny", "deny": "deny", "拒绝": "deny", "不同意": "deny",
              "第一项": "1", "选项一": "1", "选择第一项": "1",
              "第二项": "2", "选项二": "2", "选择第二项": "2",
              "第三项": "3", "选项三": "3", "选择第三项": "3",
              "第四项": "4", "选项四": "4", "选择第四项": "4"}
# 群内远程执行 ccr 白名单命令(私人群+sender=本人才进入路由, 见 main)
CCR_CMD_RE = re.compile(
    r"^ccr\s+(dingtalk-notify|b)\s+(on|off)$"
    r"|^ccr\s+(status|inbox)$"
    r"|^ccr\s+set\s+inject\s+(on|off)$"
    r"|^ccr\s+set\s+(bwait|await|webhook|websecret)\s+\S+$")


def log(msg):
    try:
        with open(DAEMON_LOG, "a") as f:
            f.write("%s %s\n" % (datetime.now().strftime("%F %T"), msg))
    except OSError:
        pass


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_json(path, data):
    tmp = path + ".tmp"
    try:
        with open(tmp, "w") as f:
            json.dump(data, f, ensure_ascii=False)
        os.replace(tmp, path)
    except OSError as e:
        log("save %s fail: %s" % (path, e))


def notify(title, body):
    try:
        subprocess.run(["/usr/bin/osascript", "-e",
                        'display notification "%s" with title "%s"' % (body, title)],
                       capture_output=True, timeout=10)
    except Exception:
        pass


def run_dws(cfg, args):
    dws = cfg.get("dws_path") or os.path.expanduser("~/.local/bin/dws")
    cmd = [dws] + args + ["--format", "json"]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=40)
        if p.returncode != 0:
            return False, p.stdout + p.stderr
        return True, p.stdout
    except Exception as e:
        return False, str(e)


def webhook_send(cfg, title, text):
    """机器人 webhook 加签直发(与 lib.sh ccr_webhook_send 等价), daemon 回执用"""
    token = cfg.get("webhook_token") or ""
    secret = cfg.get("webhook_secret") or ""
    if not token or not secret:
        return False
    ts = str(int(time.time() * 1000))
    sign = base64.b64encode(
        hmac.new(secret.encode(), ("%s\n%s" % (ts, secret)).encode(),
                 hashlib.sha256).digest()).decode()
    url = ("https://oapi.dingtalk.com/robot/send?access_token=%s&timestamp=%s&sign=%s"
           % (token, ts, quote(sign, safe="")))
    payload = {"msgtype": "markdown",
               "markdown": {"title": title, "text": SELF_MARKER + "\n" + text}}
    try:
        req = Request(url, data=json.dumps(payload).encode("utf-8"),
                      headers={"Content-Type": "application/json"})
        with urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        if data.get("errcode") == 0:
            return True
        log("webhook fail: %s" % data)
    except Exception as e:
        log("webhook fail: %s" % e)
    return False


def handle_ccr_command(text, cfg):
    """执行群内下发的白名单 ccr 命令并回执输出"""
    cmd = [os.path.join(CCR, "bin", "ccr")] + text.split()[1:]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        out = (p.stdout or "").strip()
        err = (p.stderr or "").strip()
        body = "已执行: `%s`\n\n" % text
        if out:
            body += "```\n%s\n```" % out[:800]
        if err:
            body += "\n```\n%s\n```" % err[:300]
        if p.returncode != 0:
            body += "\n(退出码 %d)" % p.returncode
        webhook_send(cfg, "ccr 远程命令", body)
        log("ccr cmd: %r rc=%d" % (text, p.returncode))
    except Exception as e:
        webhook_send(cfg, "ccr 远程命令失败", "%s\n\n%s" % (text, e))
        log("ccr cmd fail: %r %s" % (text, e))


def now_str():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def list_messages(cfg, cursor):
    """返回 (success, 按 createTime 升序的消息列表, 输出原文)"""
    args = ["chat", "message", "list", "--group", cfg.get("group_id", ""),
            "--time", cursor, "--direction", "newer", "--limit", "20"]
    if cfg.get("mode") == "bot_dm" and cfg.get("bot_open_dingtalk_id"):
        args = ["chat", "message", "list", "--open-dingtalk-id",
                cfg["bot_open_dingtalk_id"], "--time", cursor,
                "--direction", "newer", "--limit", "20"]
    ok, out = run_dws(cfg, args)
    if not ok:
        return False, [], out
    try:
        data = json.loads(out)
        msgs = (data.get("result") or {}).get("messages") or []
        msgs.sort(key=lambda m: m.get("createTime", ""))
        return True, msgs, out
    except ValueError:
        return False, [], out


def pending_tokens():
    try:
        return [f[:-5] for f in os.listdir(PENDING) if f.endswith(".json")]
    except OSError:
        return []


def newest_pending(kind=None, exclude_idle=False):
    best, best_created = None, -1
    for t in pending_tokens():
        meta = load_json(os.path.join(PENDING, "%s.json" % t), {})
        if kind and meta.get("kind") != kind:
            continue
        if exclude_idle and meta.get("kind") == "idle":
            continue
        c = meta.get("created", 0)
        if c > best_created:
            best, best_created = t, c
    return best


def write_reply(token, raw):
    s = re.sub(r"\s+", "", raw).lower()
    choice = CHOICE_MAP.get(s, "")
    if not choice:
        m = re.match(r"^([1-4])", s)
        if m:
            choice = m.group(1)
    data = {"raw": raw, "choice": choice, "at": int(time.time())}
    save_json(os.path.join(PENDING, "%s.reply" % token), data)
    log("reply %s <- %r (choice=%s)" % (token, raw, choice))


def append_inbox(text):
    ts = datetime.now().strftime("%F %T")
    try:
        with open(INBOX, "a") as f:
            f.write("[%s] %s\n" % (ts, text))
    except OSError as e:
        log("inbox write fail: %s" % e)


TMUX_CANDIDATES = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]


def tmux_bin():
    for p in TMUX_CANDIDATES:
        if os.path.exists(p):
            return p
    return ""


def inject_to_tmux(text, tty):
    """tmux: 按 pane 的 tty 定位, send-keys 等同亲手键入(含回车)"""
    tmux = tmux_bin()
    if not tmux:
        return False
    try:
        out = subprocess.run([tmux, "list-panes", "-a", "-F", "#{pane_id} #{pane_tty}"],
                             capture_output=True, text=True, timeout=10)
        for line in (out.stdout or "").splitlines():
            parts = line.split(" ", 1)
            if len(parts) == 2 and parts[1].strip().replace("/dev/", "") == tty:
                subprocess.run([tmux, "send-keys", "-t", parts[0], "-l", "--", text],
                               capture_output=True, timeout=10)
                subprocess.run([tmux, "send-keys", "-t", parts[0], "Enter"],
                               capture_output=True, timeout=10)
                return True
    except Exception as e:
        log("tmux inject fail: %s" % e)
    return False


def inject_to_terminal(text, tty):
    """Terminal.app 官方接口: 按 tty 定位 tab, do script 把文本+回车写进该 tab 的输入"""
    esc = text.replace("\\", "\\\\").replace('"', '\\"')
    script = (
        'tell application "Terminal"\n'
        'repeat with w in windows\n'
        'repeat with t in tabs of w\n'
        'if tty of t is "/dev/%s" then\n'
        'do script "%s" in t\n'
        'return "ok"\n'
        'end if\n'
        'end repeat\n'
        'end repeat\n'
        'end tell\n'
        'return "miss"' % (tty, esc)
    )
    try:
        out = subprocess.run(["/usr/bin/osascript", "-e", script],
                             capture_output=True, text=True, timeout=15)
        return (out.stdout or "").strip() == "ok"
    except Exception as e:
        log("terminal inject fail: %s" % e)
    return False


def dispatch_idle(body, meta, cfg):
    """把远程指令键入空闲会话的终端(tmux 优先, Terminal.app 兜底); 返回 ok/unsupported/off"""
    extra = meta.get("extra") or {}
    tty = (extra.get("tty") or "").strip().replace("/dev/", "")
    proj = extra.get("proj") or "该"
    if not cfg.get("terminal_inject"):
        return "off"
    if not tty.startswith("ttys"):
        return "unsupported"
    if inject_to_tmux(body, tty):
        webhook_send(cfg, "ccr 已键入终端",
                     "已把指令键入 **%s** 会话终端（tmux），等同亲手输入：\n\n> %s" % (proj, body))
        return "ok"
    if inject_to_terminal(body, tty):
        webhook_send(cfg, "ccr 已键入终端",
                     "已把指令键入 **%s** 会话终端（Terminal.app），等同亲手输入：\n\n> %s" % (proj, body))
        return "ok"
    return "unsupported"


def deliver_reply(token, body, cfg):
    meta = load_json(os.path.join(PENDING, "%s.json" % token), {})
    if meta.get("kind") == "idle":
        r = dispatch_idle(body, meta, cfg)
        log("idle %s dispatch=%s <- %r" % (token, r, body))
        if r == "ok":
            return
        extra = meta.get("extra") or {}
        append_inbox(body)
        if r == "unsupported":
            webhook_send(cfg, "ccr 无法注入该终端",
                         "**%s** 会话跑在 IDEA 内置终端（或 tty 不可用），远程无法键入。指令已落 inbox，回电脑后 `ccr inbox` 取用。\n\n"
                         "提示：会话跑在 Terminal.app 或 tmux 里即可远程直达。" % (extra.get("proj") or "该"))
        else:
            webhook_send(cfg, "ccr 已收到", "> %s\n\n已落 inbox（终端注入未开启，可 `ccr set inject on`）。" % body)
        return
    write_reply(token, body)


def handle_free_text(text, cfg):
    append_inbox(text)
    ack = ("已落 inbox。电脑上取回: `ccr inbox`\n\n"
           "提示：AI 空闲时**引用**「空闲等待」消息发指令，可直接键入该会话终端执行（Terminal.app / tmux）。")
    webhook_send(cfg, "ccr 已收到", "> %s\n\n%s" % (text, ack))
    log("free-text: %r" % text)


# @提及剥离: 机器人名「AI Coding」含空格需整体匹配; 其他单词 @ 提及(如 @段凤)仅剥离不计为机器人
MENTION_RE = re.compile(r"^(@AI\s*Coding(?:\s*机器人)?|@\S+)\s+")


def route(text, cfg):
    raw = text.strip()
    # 钉钉引用回复在消息拉取接口里没有引用元数据, 但会自动带 @机器人 前缀 —— 语义=回复最新询问
    # 注意机器人名「AI Coding」本身含空格, 需整体匹配; 其他单词 @ 提及(如 @段凤)仅剥离不计为机器人
    at_bot, body = False, raw
    while True:
        m = MENTION_RE.match(body)
        if not m:
            break
        w = m.group(1).lower()
        if w.startswith("@ai") or "coding" in w or "ccr" in w:
            at_bot = True
        body = body[m.end():].lstrip()
    if not body:
        return
    if CCR_CMD_RE.match(body):
        handle_ccr_command(body, cfg)
        return
    m = TOKEN_RE.match(body)
    if m and os.path.exists(os.path.join(PENDING, "%s.json" % m.group(1))):
        deliver_reply(m.group(1), m.group(2).strip() or body, cfg)
        return
    if at_bot:
        # 引用回复: 数字=回答询问(优先 ask/perm), 文字=指令(优先空闲会话)
        if BARE_CHOICE_RE.match(body):
            target = newest_pending(exclude_idle=True) or newest_pending()
        else:
            target = newest_pending("idle") or newest_pending()
        if target:
            deliver_reply(target, body, cfg)
            return
    # 引用内容内嵌 token 的兜底: 命中唯一未决 token 则路由, 最后一行视为用户回复正文
    toks = set(re.findall(r"(?<![a-z0-9])[a-z0-9]{4}(?![a-z0-9])", body)) & set(pending_tokens())
    if len(toks) == 1:
        deliver_reply(toks.pop(), body.splitlines()[-1].strip(), cfg)
        return
    if BARE_CHOICE_RE.match(body):
        pend = [t for t in pending_tokens()
                if load_json(os.path.join(PENDING, "%s.json" % t), {}).get("kind") != "idle"]
        if len(pend) == 1:
            deliver_reply(pend[0], body, cfg)
            return
        if len(pend) > 1:
            names = ", ".join(
                "%s(%s)" % (t, load_json(os.path.join(PENDING, t + ".json"), {}).get("kind", ""))
                for t in pend)
            webhook_send(cfg, "ccr 待确认有歧义",
                         "当前有 %d 个未决询问: %s\n\n请回复 `<token> 数字`，或**引用**对应消息直接回复。" % (len(pend), names))
            log("ambiguous bare choice, pendings=%s" % pend)
            return
    # 有空闲会话待命: 自由文本默认作为给它的指令, 直接键入其终端
    idle_t = newest_pending("idle")
    if idle_t:
        deliver_reply(idle_t, body, cfg)
        return
    handle_free_text(raw, cfg)


def cleanup_pending(max_age=1800):
    now = time.time()
    try:
        for f in os.listdir(PENDING):
            p = os.path.join(PENDING, f)
            try:
                if now - os.path.getmtime(p) > max_age:
                    os.remove(p)
            except OSError:
                pass
    except OSError:
        pass


def auth_alert_throttled(state):
    last = state.get("auth_alert_at", 0)
    if time.time() - last < 3600:
        return False
    state["auth_alert_at"] = int(time.time())
    return True


def main():
    state = load_json(STATE_PATH, {})
    if not state.get("cursor"):
        state["cursor"] = now_str()  # 首次启动忽略历史消息
        state["seen"] = []
        save_json(STATE_PATH, state)
    seen = set(state.get("seen", []))
    log("daemon start, cursor=%s" % state["cursor"])

    while True:
        cfg = load_json(CFG_PATH, {})
        if not cfg.get("switch_b"):
            time.sleep(30)
            continue
        poll = max(5, int(cfg.get("poll_interval", 15)))

        ok, msgs, out = list_messages(cfg, state["cursor"])
        if not ok:
            low = out.lower()
            if "token" in low or "auth" in low or "login" in low or "401" in low:
                if auth_alert_throttled(state):
                    notify("cc-remote", "dws 登录疑似失效，请运行 dws 检查登录")
                    webhook_send(cfg, "ccr 告警", "dws 登录疑似失效，回复将收不到；回电脑后运行 `ccr doctor` 检查")
                    log("auth fail: %s" % out[:200])
                save_json(STATE_PATH, state)
            else:
                log("poll fail: %s" % out[:200])
            time.sleep(60)
            continue

        user_name = cfg.get("user_name", "")
        for m in msgs:
            mid = m.get("openMessageId", "")
            created = m.get("createTime", "")
            if created:
                state["cursor"] = max(state["cursor"], created)
            if not mid or mid in seen:
                continue
            seen.add(mid)
            # 只处理用户本人的消息(跳过机器人/自己系统发的通知)
            if m.get("sender") != user_name:
                continue
            content = (m.get("content") or "").strip()
            if not content or SELF_MARKER in content:
                continue
            log("user msg: %r" % content[:100])
            try:
                route(content, cfg)
            except Exception as e:
                log("route error: %s" % e)

        seen = set(list(seen)[-500:])
        state["seen"] = list(seen)
        save_json(STATE_PATH, state)
        cleanup_pending()
        try:
            with open(os.path.join(CCR, "logs", "daemon.heartbeat"), "w") as f:
                f.write(str(int(time.time())))
        except OSError:
            pass
        time.sleep(poll)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
