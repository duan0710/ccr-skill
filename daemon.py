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
# 会话注册表(UserPromptSubmit hook 写入): {sid, tty, cwd, last_seen}
SESSIONS_DIR = os.path.join(CCR, "sessions")
# 无头任务记录与并发锁
TASKS_DIR = os.path.join(CCR, "tasks")
TASK_LOCK = os.path.join(TASKS_DIR, ".lock")

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
# ccr start: 无活跃会话时手机开新 Terminal 会话(claude/codex), 余下任意文本=首条指令
CCR_CMD_RE = re.compile(
    r"^ccr\s+(dingtalk-notify|b)\s+(on|off)$"
    r"|^ccr\s+(status|inbox|tasks)\s*$"
    r"|^ccr\s+set\s+(inject|task)\s+(on|off)$"
    r"|^ccr\s+set\s+(bwait|await|webhook|websecret)\s+\S+$"
    r"|^ccr\s+start\s+(claude|codex)(\s+\S.*)?$")


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


def ensure_dirs():
    for d in (PENDING, SESSIONS_DIR, TASKS_DIR):
        try:
            os.makedirs(d, exist_ok=True)
        except OSError:
            pass


def tty_alive(tty):
    """终端设备是否仍存在(关闭终端/tab 会释放 ttysXXX)"""
    if not tty:
        return False
    dev = tty if tty.startswith("/dev/") else "/dev/%s" % tty
    return os.path.exists(dev)


def pid_holds_tty(pid, tty):
    """pid 存活且控制终端仍是注册的 tty(防重启后 ttys 编号复用打错窗口)"""
    if not pid or not tty:
        return False
    try:
        out = subprocess.run(["/bin/ps", "-o", "tty=", "-p", str(pid)],
                             capture_output=True, text=True, timeout=5)
        cur = (out.stdout or "").strip().replace("/dev/", "")
        return out.returncode == 0 and bool(cur) and cur == tty.replace("/dev/", "")
    except Exception:
        return False


def session_valid(meta):
    """会话可注入的真判据: claude pid 存活且仍持有该 tty, 且终端宿主是 Terminal.app/tmux

    IDEA 内置终端虽跑着 claude 但无法注入(macOS 限制, 注入了也收不到), 直接判不可注入
    """
    tty = (meta.get("tty") or "").strip()
    pid = str(meta.get("pid") or "").strip()
    checked_pid = None
    if pid:
        if not pid_holds_tty(pid, tty):
            return False
        checked_pid = int(pid)
    else:
        if not tty.startswith("ttys"):
            return False
        try:  # 旧版条目无 pid: 取 tty 上任一 claude 进程做宿主校验
            out = subprocess.run(["/bin/ps", "-o", "comm=,pid=", "-t", tty],
                                 capture_output=True, text=True, timeout=5)
            for ln in (out.stdout or "").splitlines():
                if "claude" in ln:
                    checked_pid = int(ln.split()[-1])
                    break
            if checked_pid is None:
                return False
        except Exception:
            return False
    return terminal_injectable(checked_pid)


def terminal_injectable(pid):
    """pid 的控制终端宿主是否 Terminal.app 或 tmux(可注入); IDEA 等返回 False"""
    try:
        # 沿父链向上找 GUI app / tmux: 每步查 comm
        cur = int(pid)
        for _ in range(10):
            out = subprocess.run(["/bin/ps", "-o", "ppid=,comm=", "-p", str(cur)],
                                 capture_output=True, text=True, timeout=5)
            parts = (out.stdout or "").strip().split(None, 1)
            if len(parts) != 2:
                return False
            ppid, comm = int(parts[0]), parts[1]
            base = comm.rsplit("/", 1)[-1]
            if base == "tmux" or "tmux" in comm:
                return True
            if base == "Terminal":  # /System/.../Terminal.app/Contents/MacOS/Terminal
                return True
            cur = ppid
            if cur <= 1:
                return False
    except Exception:
        return False
    return False


def active_sessions():
    """按最近活跃排序返回所有**可注入**会话(无任何时间限制)

    有效性只看进程归属: claude pid 活着且仍挂注册的 tty(闲置任意久都行)。
    无效条目(pid 消失/tty 被新进程复用)当场删除 —— 注册表自洁不膨胀。
    占位条目(仅别名, tty/pid 空, perm hook 早于 status hook 生成)保留但不可注入。
    """
    items = []
    try:
        names = os.listdir(SESSIONS_DIR)
    except OSError:
        return items
    for name in names:
        if not name.endswith(".json"):
            continue
        path = os.path.join(SESSIONS_DIR, name)
        meta = load_json(path, {})
        if not (meta.get("tty") or "").strip() and not (meta.get("pid") or "").strip():
            items.append(meta)  # 占位(别名)条目: 不校验不删除
            continue
        if not session_valid(meta):
            try:
                os.remove(path)
                log("session purge: %s tty=%s pid=%s" % (name[:16], meta.get("tty"), meta.get("pid")))
            except OSError:
                pass
            continue
        items.append(meta)
    items.sort(key=lambda m: m.get("last_seen", 0), reverse=True)
    return items


def run_headless_task(text, cfg):
    """没有活跃会话时, 后台起 claude -p 执行新任务

    - 单并发(TASK_LOCK), 超时 30min, 结果发回钉钉
    - 权限链路沿用 settings.json 中的 PermissionRequest hook(理论上 -p 也会触发)
    - 任务记录全文落 tasks/<ts>.log
    """
    if os.path.exists(TASK_LOCK):
        return "busy", "已有无头任务在跑, 稍后再试"
    ensure_dirs()
    try:
        with open(TASK_LOCK, "w") as f:
            f.write(str(int(time.time())))
    except OSError:
        pass
    log("headless task start: %r" % text[:200])
    # 选 claude 二进制: 优先 PATH(nvm), 兜底常见安装位置
    claude = shutil.which("claude") or os.path.expanduser("~/.nvm/versions/node")
    if os.path.isdir(claude):
        # ~/.nvm/versions/node/vX/bin/claude — 找最新版本
        try:
            for v in sorted(os.listdir(claude), reverse=True):
                cand = os.path.join(claude, v, "bin", "claude")
                if os.path.exists(cand):
                    claude = cand
                    break
        except OSError:
            pass
    if not os.path.exists(claude):
        os.remove(TASK_LOCK)
        return "fail", "未找到 claude 二进制(需 nvm 装好并登录)"
    # 权限模式: 远程确认开则 default(hook 会发钉钉), 否则 plan(只读最安全)
    perm = "default" if cfg.get("switch_b") else "plan"
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    log_path = os.path.join(TASKS_DIR, ts + ".log")
    try:
        with open(log_path, "w") as lf:
            lf.write(">>> %s\n\n" % text)
            lf.flush()
            p = subprocess.run([claude, "-p", "--permission-mode", perm, text],
                               capture_output=True, text=True, timeout=1800,
                               env=dict(os.environ, CI="1"))
            out = (p.stdout or "") + (p.stderr or "")
            lf.write("rc=%d\n%s\n" % (p.returncode, out))
    except subprocess.TimeoutExpired:
        with open(log_path, "a") as lf:
            lf.write("\n(超时 30min, 已终止)\n")
        return "timeout", "无头任务执行超 30min 已终止, 日志: tasks/%s.log" % ts
    except Exception as e:
        os.remove(TASK_LOCK)
        log("headless task fail: %s" % e)
        return "fail", str(e)
    finally:
        try:
            os.remove(TASK_LOCK)
        except OSError:
            pass
    # 结果 @回群(截断, 全文在 log)
    snippet = out.strip()[:1500] or "(空输出)"
    webhook_send(cfg, "ccr 无头任务完成", "## 任务: %s\n\n```\n%s\n```\n\n全文: `tasks/%s.log`"
                 % (text[:80], snippet, ts))
    return "ok", "无头任务完成, 全文见 tasks/%s.log" % ts


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
    total = None
    for attempt in (1, 2):  # AppleScript 写入偶发卡死(高负载/模态框), 重试一次
        try:
            out = subprocess.run(["/usr/bin/osascript", "-e", script],
                                 capture_output=True, text=True, timeout=20)
            total = (out.stdout or "").strip()
            if total == "ok":
                return True
            log("terminal inject miss/err attempt %d: %r %r" % (attempt, total, (out.stderr or "")[:120]))
            if total == "miss":
                return False  # tty 不在 Terminal.app 窗口里(tmux/IDEA), 重试无意义
        except Exception as e:
            log("terminal inject fail attempt %d: %s" % (attempt, e))
    return total == "ok"


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
    n_sess = len(active_sessions())
    ack = ("**未能送达 AI** — 已存 inbox，需**回电脑**处理: `ccr inbox`\n\n"
           "当前可注入会话: %d 个。要手机直接派活：①在 Terminal.app/tmux 里开 claude 会话 ②或 `ccr set task on` 开无头执行" % n_sess)
    webhook_send(cfg, "ccr 未送达(存inbox)", "> %s\n\n%s" % (text, ack))
    log("free-text(未送达): %r" % text)


# @提及剥离: 机器人名「AI Coding」含空格需整体匹配; 其他单词 @ 提及(如 @段凤)仅剥离不计为机器人
MENTION_RE = re.compile(r"^(@AI\s*Coding(?:\s*机器人)?|@\S+)\s+")

# 引用回复精确路由: 拉取接口的 quotedMessage.content 是被引用卡片完整正文
# (2026-09-25 验证 dws chat message list 已返回该字段; 旧版无引用元数据只能按最新兜底)
CARD_TOKEN_RES = [
    re.compile(r"## 权限确认[^a-z0-9]*([a-z0-9]{4})(?![a-z0-9])"),
    re.compile(r"## 待确认[^a-z0-9]*([a-z0-9]{4})(?![a-z0-9])"),
    re.compile(r"## Claude[^\n]{0,40}?([a-z0-9]{4})(?![a-z0-9])"),
    re.compile(r"(?:ccr reply|回复 `)\s*([a-z0-9]{4})"),
]


def route_quoted(body, msg, cfg):
    """引用了本系统卡片时的精确路由, 返回 True 表示已处理:

    - 卡片票据未决 -> 回复路由到**该票据**(而非最新)
    - 票据已结束(已处理/超时) -> 仅回执说明, 不做任何注入/兜底
      (用户决策: 明确提示优于自作聪明的注入, 指定会话请显式用「别名 指令」)
    """
    q = (msg or {}).get("quotedMessage") or {}
    qc = (q.get("content") or "").strip()
    if not qc or SELF_MARKER not in qc:
        return False
    for rx in CARD_TOKEN_RES:
        for tok in rx.findall(qc):
            if os.path.exists(os.path.join(PENDING, tok + ".json")):
                log("quote -> pending ticket %s" % tok)
                deliver_reply(tok, body, cfg)
                return True
    webhook_send(cfg, "ccr 卡片已处理",
                 "引用的卡片对应确认已结束（已处理或超时），本次输入未执行：\n\n> %s\n\n最新确认可直接回复数字（或引用最新卡片）；给指定会话发指令请用 `别名 指令`。" % body)
    log("quote stale card, ignored")
    return True


def route(text, cfg, msg=None):
    raw = text.strip()
    # 引用回复已能精确路由(quotedMessage 含被引用卡片全文); 手打 @机器人 仍按"回复最新询问"语义
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
    # 引用了本系统卡片: 精确路由(未决票据 > 卡上会话别名), 优先于 token/别名/最新兜底
    if route_quoted(body, msg, cfg):
        return
    m = TOKEN_RE.match(body)
    if m and os.path.exists(os.path.join(PENDING, "%s.json" % m.group(1))):
        deliver_reply(m.group(1), m.group(2).strip() or body, cfg)
        return
    # 会话别名定向: "<别名> 指令" -> 键入该会话终端(未决 token 已优先命中, 不冲突)
    words = body.split(None, 1)
    if words and re.fullmatch(r"[a-z0-9]{4}", words[0]) and re.search(r"[a-z]", words[0]):
        target = None
        for meta in active_sessions():
            if meta.get("alias") == words[0]:
                target = meta
                break
        if target:
            rest = words[1].strip() if len(words) > 1 else ""
            proj = (target.get("cwd") or "claude").split("/")[-1]
            if not rest:
                webhook_send(cfg, "ccr 会话指令为空", "会话 **%s**（%s）在线。用法：`%s 指令内容`" % (words[0], proj, words[0]))
                log("alias %s empty cmd" % words[0])
                return
            tty = (target.get("tty") or "").replace("/dev/", "")
            if inject_to_tmux(rest, tty) or inject_to_terminal(rest, tty):
                webhook_send(cfg, "ccr 已键入终端",
                             "已把指令键入会话 **%s**（%s）终端，等同亲手输入（忙碌则排队）：\n\n> %s"
                             % (words[0], proj, rest))
            else:
                webhook_send(cfg, "ccr 无法注入该终端",
                             "会话 **%s**（%s）跑在 IDEA 内置终端或 tty 不可用，无法键入。" % (words[0], proj))
            log("alias %s dispatch tty=%s" % (words[0], tty))
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
    # 可注入会话(无时限, pid 归属校验): 新到旧逐个试(最新的可能是 IDEA 等注入不了的)
    for sess in active_sessions():
        tty = sess.get("tty", "").replace("/dev/", "")
        if inject_to_tmux(body, tty) or inject_to_terminal(body, tty):
            webhook_send(cfg, "ccr 已键入终端",
                         "已把指令键入会话终端(**%s**), 等同亲手输入(Claude 忙则排队):\n\n> %s"
                         % ((sess.get("cwd") or "claude").split("/")[-1], body))
            log("injected to session tty=%s proj=%s" % (tty, (sess.get("cwd") or "")[-30:]))
            return
    # 有空闲会话待命: 自由文本默认作为给它的指令, 直接键入其终端
    idle_t = newest_pending("idle")
    if idle_t:
        deliver_reply(idle_t, body, cfg)
        return
    # 无活跃会话且开启了无头任务: 后台起 claude -p 执行
    if cfg.get("task_enabled"):
        status, msg = run_headless_task(raw, cfg)
        webhook_send(cfg, "ccr 任务状态", "%s\n\n%s" % (msg, raw[:200]))
        log("headless task %s: %r" % (status, raw[:80]))
        return
    handle_free_text(raw, cfg)


def cleanup_pending(max_age=1800):
    """过期票据回收: 普通(perm/ask)30 分钟; 空闲票据 7 天(其累积由 notify.sh 同会话去重控制)"""
    now = time.time()
    idle_max_age = 7 * 86400
    try:
        for f in os.listdir(PENDING):
            p = os.path.join(PENDING, f)
            try:
                limit = idle_max_age if (f.endswith(".json") and
                                         load_json(p, {}).get("kind") == "idle") else max_age
                if now - os.path.getmtime(p) > limit:
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
    ensure_dirs()
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
                route(content, cfg, m)
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
