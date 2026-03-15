#!/usr/bin/env bash
set -euo pipefail

########################################
# 请修改下面这个变量
########################################
BOT_TOKEN="BOT_TOKEN"

# agent-cards 命令路径
# 如果 which agent-cards 能找到，可保持默认
# 否则改成完整路径，例如 /usr/local/bin/agent-cards
AGENT_CARDS_CMD="agent-cards"

# 登录邮箱
AGENT_LOGIN_EMAIL="XXX@gmail.com"

# 只允许这个 Telegram 用户使用
ALLOWED_USER_IDS="Telegram_ID"

# 可选：限制允许金额，例如 "1,5,10"
# 留空表示不限制
ALLOWED_AMOUNTS=""

APP_DIR="/opt/telegram-card-bot"
SERVICE_NAME="telegram-card-bot"

########################################
# 基础检查
########################################
if [[ $EUID -ne 0 ]]; then
  echo "请用 root 运行此脚本"
  exit 1
fi

if [[ -z "$BOT_TOKEN" ]]; then
  echo "请先修改 BOT_TOKEN"
  exit 1
fi

echo "==> 清理旧版本（如存在）"
systemctl stop "$SERVICE_NAME" 2>/dev/null || true
systemctl disable "$SERVICE_NAME" 2>/dev/null || true
rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload || true
systemctl reset-failed || true
rm -rf "$APP_DIR"

echo "==> 安装系统依赖"
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y python3 python3-venv python3-pip

echo "==> 创建项目目录"
mkdir -p "$APP_DIR"
cd "$APP_DIR"

echo "==> 写入 requirements.txt"
cat > "$APP_DIR/requirements.txt" <<'EOF'
python-telegram-bot==21.6
python-dotenv==1.0.1
pexpect==4.9.0
EOF

echo "==> 写入 .env"
cat > "$APP_DIR/.env" <<EOF
BOT_TOKEN=$BOT_TOKEN
AGENT_CARDS_CMD=$AGENT_CARDS_CMD
AGENT_LOGIN_EMAIL=$AGENT_LOGIN_EMAIL
ALLOWED_USER_IDS=$ALLOWED_USER_IDS
ALLOWED_AMOUNTS=$ALLOWED_AMOUNTS
EOF

echo "==> 写入 bot.py"
cat > "$APP_DIR/bot.py" <<'PYEOF'
import asyncio
import logging
import os
import re
import shlex
import time
from dataclasses import dataclass
from typing import Dict, Optional

import pexpect
from dotenv import load_dotenv
from telegram import Update
from telegram.ext import (
    Application,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

load_dotenv()

logging.basicConfig(
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    level=logging.INFO,
    force=True,
)
logger = logging.getLogger(__name__)

BOT_TOKEN = os.getenv("BOT_TOKEN", "").strip()
AGENT_CARDS_CMD = os.getenv("AGENT_CARDS_CMD", "agent-cards").strip()
AGENT_LOGIN_EMAIL = os.getenv("AGENT_LOGIN_EMAIL", "cosdayan@gmail.com").strip()
ALLOWED_USER_IDS_RAW = os.getenv("ALLOWED_USER_IDS", "1847949142").strip()
ALLOWED_AMOUNTS_RAW = os.getenv("ALLOWED_AMOUNTS", "").strip()

if not BOT_TOKEN:
    raise ValueError("BOT_TOKEN 未配置")

ALLOWED_USER_IDS = set()
if ALLOWED_USER_IDS_RAW:
    for x in ALLOWED_USER_IDS_RAW.split(","):
        x = x.strip()
        if x.isdigit():
            ALLOWED_USER_IDS.add(int(x))

ALLOWED_AMOUNTS = set()
if ALLOWED_AMOUNTS_RAW:
    for x in ALLOWED_AMOUNTS_RAW.split(","):
        x = x.strip()
        if x:
            ALLOWED_AMOUNTS.add(x)


@dataclass
class SessionState:
    stage: str = "idle"  # idle / waiting_amount / generating / waiting_login_confirm
    amount: Optional[str] = None
    created_at: float = 0.0


user_sessions: Dict[int, SessionState] = {}

APP: Optional[Application] = None
MAIN_LOOP: Optional[asyncio.AbstractEventLoop] = None


def is_allowed_user(user_id: int) -> bool:
    if not ALLOWED_USER_IDS:
        return True
    return user_id in ALLOWED_USER_IDS


def is_allowed_amount(amount: str) -> bool:
    if not ALLOWED_AMOUNTS:
        return True
    return amount in ALLOWED_AMOUNTS


def get_or_create_session(chat_id: int) -> SessionState:
    if chat_id not in user_sessions:
        user_sessions[chat_id] = SessionState(created_at=time.time())
    return user_sessions[chat_id]


def reset_session(chat_id: int):
    user_sessions[chat_id] = SessionState(created_at=time.time())


def cleanup_expired_sessions(max_age_seconds: int = 1800):
    now = time.time()
    expired = []
    for chat_id, session in user_sessions.items():
        if now - session.created_at > max_age_seconds:
            expired.append(chat_id)
    for chat_id in expired:
        reset_session(chat_id)


def clean_text(text: str) -> str:
    ansi_escape = re.compile(r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")
    text = ansi_escape.sub("", text)
    text = text.replace("\r", "")
    return text.strip()


def escape_markdown_v2(text: str) -> str:
    special_chars = r'_*\[\]()~`>#+-=|{}.!'
    for ch in special_chars:
        text = text.replace(ch, f'\\{ch}')
    return text


def split_message(text: str, limit: int = 3500):
    text = text or ""
    if len(text) <= limit:
        return [text]
    parts = []
    while text:
        parts.append(text[:limit])
        text = text[limit:]
    return parts


async def tg_send(chat_id: int, text: str, parse_mode: Optional[str] = None):
    global APP
    if not APP:
        return
    for part in split_message(text):
        await APP.bot.send_message(chat_id=chat_id, text=part, parse_mode=parse_mode)


def sync_tg_send(chat_id: int, text: str, parse_mode: Optional[str] = None):
    global MAIN_LOOP
    if not MAIN_LOOP:
        logger.warning("MAIN_LOOP 未初始化，无法发送 Telegram 消息")
        return
    future = asyncio.run_coroutine_threadsafe(
        tg_send(chat_id, text, parse_mode=parse_mode),
        MAIN_LOOP,
    )
    try:
        future.result(timeout=30)
    except Exception as e:
        logger.exception("发送 Telegram 消息失败: %s", e)


def send_step(chat_id: int, title: str, body: str = ""):
    msg = title
    if body:
        msg += f"\n{body}"
    sync_tg_send(chat_id, msg)


def send_output(chat_id: int, output: str):
    output = clean_text(output)
    if output:
        sync_tg_send(chat_id, f"输出：\n{output}")


def find_value(pattern: str, text: str) -> str:
    m = re.search(pattern, text, re.IGNORECASE | re.MULTILINE)
    return m.group(1).strip() if m else ""


def extract_card_id(create_output: str) -> str:
    patterns = [
        r'agent-cards\s+cards\s+details\s+([a-zA-Z0-9_-]{8,})',
        r'\bdetails\s+([a-zA-Z0-9_-]{8,})',
        r'\bcard\s+id\s*[:：]\s*([a-zA-Z0-9_-]{8,})',
        r'\bid\s*[:：]\s*([a-zA-Z0-9_-]{8,})',
    ]
    for pattern in patterns:
        m = re.search(pattern, create_output, re.IGNORECASE)
        if m:
            return m.group(1).strip()
    return ""


def is_not_logged_in(output: str) -> bool:
    text = output.lower()
    return (
        "not logged in" in text
        or "session expired" in text
        or "run: agent-cards login" in text
    )


def spoiler_sensitive_output(text: str) -> str:
    lines = text.splitlines()
    new_lines = []

    for line in lines:
        m_pan = re.match(r'(?i)^\s*(PAN)\s+(.+?)\s*$', line)
        if m_pan:
            new_lines.append(f"*PAN:* ||{escape_markdown_v2(m_pan.group(2).strip())}||")
            continue

        m_cvv = re.match(r'(?i)^\s*(CVV)\s+(.+?)\s*$', line)
        if m_cvv:
            new_lines.append(f"*CVV:* ||{escape_markdown_v2(m_cvv.group(2).strip())}||")
            continue

        m_expiry = re.match(r'(?i)^\s*(Expiry)\s+(.+?)\s*$', line)
        if m_expiry:
            new_lines.append(f"*Expiry:* {escape_markdown_v2(m_expiry.group(2).strip())}")
            continue

        m_balance = re.match(r'(?i)^\s*(Balance)\s+(.+?)\s*$', line)
        if m_balance:
            new_lines.append(f"*Balance:* {escape_markdown_v2(m_balance.group(2).strip())}")
            continue

        m_status = re.match(r'(?i)^\s*(Status)\s+(.+?)\s*$', line)
        if m_status:
            new_lines.append(f"*Status:* {escape_markdown_v2(m_status.group(2).strip())}")
            continue

        if line.strip():
            new_lines.append(escape_markdown_v2(line))

    return "\n".join(new_lines).strip()


def format_details_message(card_id: str, details_raw: str) -> str:
    details_raw = clean_text(details_raw)

    pan = find_value(r'^\s*PAN\s+(.+?)\s*$', details_raw)
    cvv = find_value(r'^\s*CVV\s+(.+?)\s*$', details_raw)
    expiry = find_value(r'^\s*Expiry\s+(.+?)\s*$', details_raw)
    balance = find_value(r'^\s*Balance\s+(.+?)\s*$', details_raw)
    status = find_value(r'^\s*Status\s+(.+?)\s*$', details_raw)

    if any([pan, cvv, expiry, balance, status]):
        lines = ["*生成成功*", ""]
        lines.append(f"*Card ID:* `{escape_markdown_v2(card_id)}`")
        if pan:
            lines.append(f"*PAN:* ||{escape_markdown_v2(pan)}||")
        if cvv:
            lines.append(f"*CVV:* ||{escape_markdown_v2(cvv)}||")
        if expiry:
            lines.append(f"*Expiry:* {escape_markdown_v2(expiry)}")
        if balance:
            lines.append(f"*Balance:* {escape_markdown_v2(balance)}")
        if status:
            lines.append(f"*Status:* {escape_markdown_v2(status)}")
        return "\n".join(lines)

    fallback = spoiler_sensitive_output(details_raw)
    return f"*生成成功*\n\n*Card ID:* `{escape_markdown_v2(card_id)}`\n{fallback}"


def run_create_command(amount: str, chat_id: int, timeout: int = 300) -> str:
    cmd = f"{shlex.quote(AGENT_CARDS_CMD)} cards create --amount {shlex.quote(amount)}"
    logger.info("Running create command: %s", cmd)
    send_step(chat_id, f"执行命令：{cmd}")

    child = pexpect.spawn(
        cmd,
        encoding="utf-8",
        timeout=timeout,
        echo=False
    )

    chunks = []
    end_time = time.time() + timeout
    sent_yes = False
    prompt_buffer = ""

    while time.time() < end_time:
        try:
            child.expect([pexpect.TIMEOUT, pexpect.EOF, r".+"], timeout=1)

            if child.after is pexpect.EOF:
                if child.before:
                    text = str(child.before)
                    chunks.append(text)
                    cleaned = clean_text(text)
                    if cleaned:
                        send_output(chat_id, cleaned)
                        prompt_buffer += "\n" + cleaned
                break

            if child.before:
                text = str(child.before)
                chunks.append(text)
                cleaned = clean_text(text)
                if cleaned:
                    send_output(chat_id, cleaned)
                    prompt_buffer += "\n" + cleaned

            if child.after and child.after not in (pexpect.EOF, pexpect.TIMEOUT):
                text = str(child.after)
                chunks.append(text)
                cleaned = clean_text(text)
                if cleaned:
                    send_output(chat_id, cleaned)
                    prompt_buffer += "\n" + cleaned

            if len(prompt_buffer) > 4000:
                prompt_buffer = prompt_buffer[-4000:]

            lower_buf = prompt_buffer.lower()

            if (
                "not logged in" in lower_buf
                or "session expired" in lower_buf
                or "run: agent-cards login" in lower_buf
            ):
                logger.info("Detected login required during create")
                break

            if not sent_yes:
                if (
                    "create a $" in lower_buf
                    and "single-use card" in lower_buf
                    and (
                        "(y/n)" in lower_buf
                        or "[y/n]" in lower_buf
                        or lower_buf.strip().endswith("?")
                    )
                ):
                    logger.info("Detected create confirmation prompt, auto sending Y")
                    send_step(chat_id, "检测到确认提示，自动输入：Y 并回车")
                    child.sendline("Y")
                    chunks.append("Y\n")
                    sent_yes = True
                    prompt_buffer += "\nY"
                    continue

        except pexpect.TIMEOUT:
            if not child.isalive():
                break
            continue
        except Exception as e:
            logger.exception("run_create_command error: %s", e)
            send_step(chat_id, f"执行 create 时发生异常：{e}")
            break

    try:
        if child.isalive():
            child.close(force=True)
    except Exception:
        pass

    output = clean_text("".join(chunks))
    logger.info("Create command finished, output length=%s", len(output))
    logger.info("Create command output:\n%s", output)
    return output


def run_login_command(chat_id: int, email: str, timeout: int = 180) -> str:
    cmd = f"{shlex.quote(AGENT_CARDS_CMD)} login"
    logger.info("Running login command: %s", cmd)
    send_step(chat_id, f"执行命令：{cmd}")

    child = pexpect.spawn(
        cmd,
        encoding="utf-8",
        timeout=timeout,
        echo=False
    )

    chunks = []
    end_time = time.time() + timeout
    email_sent = False
    prompt_buffer = ""

    while time.time() < end_time:
        try:
            child.expect([pexpect.TIMEOUT, pexpect.EOF, r".+"], timeout=1)

            if child.after is pexpect.EOF:
                if child.before:
                    text = str(child.before)
                    chunks.append(text)
                    cleaned = clean_text(text)
                    if cleaned:
                        send_output(chat_id, cleaned)
                        prompt_buffer += "\n" + cleaned
                break

            if child.before:
                text = str(child.before)
                chunks.append(text)
                cleaned = clean_text(text)
                if cleaned:
                    send_output(chat_id, cleaned)
                    prompt_buffer += "\n" + cleaned

            if child.after and child.after not in (pexpect.EOF, pexpect.TIMEOUT):
                text = str(child.after)
                chunks.append(text)
                cleaned = clean_text(text)
                if cleaned:
                    send_output(chat_id, cleaned)
                    prompt_buffer += "\n" + cleaned

            if len(prompt_buffer) > 4000:
                prompt_buffer = prompt_buffer[-4000:]

            lower_buf = prompt_buffer.lower()

            if not email_sent and (
                "enter your email address" in lower_buf
                or "email address" in lower_buf
            ):
                send_step(chat_id, f"检测到邮箱输入提示，自动输入邮箱：{email} 并回车")
                child.sendline(email)
                chunks.append(email + "\n")
                email_sent = True
                prompt_buffer += "\n" + email
                continue

            if "magic link sent to" in lower_buf:
                logger.info("Magic link has been sent")
                break

        except pexpect.TIMEOUT:
            if not child.isalive():
                break
            continue
        except Exception as e:
            logger.exception("run_login_command error: %s", e)
            send_step(chat_id, f"执行 login 时发生异常：{e}")
            break

    try:
        if child.isalive():
            child.close(force=True)
    except Exception:
        pass

    output = clean_text("".join(chunks))
    logger.info("Login command output:\n%s", output)
    return output


def fetch_details(card_id: str, chat_id: int) -> str:
    cmd = f"{shlex.quote(AGENT_CARDS_CMD)} cards details {shlex.quote(card_id)}"
    logger.info("Running details command: %s", cmd)
    send_step(chat_id, f"执行命令：{cmd}")

    child = pexpect.spawn(
        cmd,
        encoding="utf-8",
        timeout=120,
        echo=False
    )

    chunks = []
    end_time = time.time() + 120

    while time.time() < end_time:
        try:
            child.expect([pexpect.TIMEOUT, pexpect.EOF, r".+"], timeout=1)

            if child.after is pexpect.EOF:
                if child.before:
                    text = str(child.before)
                    chunks.append(text)
                    cleaned = clean_text(text)
                    if cleaned:
                        send_output(chat_id, cleaned)
                break

            if child.before:
                text = str(child.before)
                chunks.append(text)
                cleaned = clean_text(text)
                if cleaned:
                    send_output(chat_id, cleaned)

            if child.after and child.after not in (pexpect.EOF, pexpect.TIMEOUT):
                text = str(child.after)
                chunks.append(text)
                cleaned = clean_text(text)
                if cleaned:
                    send_output(chat_id, cleaned)

        except pexpect.TIMEOUT:
            if not child.isalive():
                break
            continue
        except Exception as e:
            logger.exception("fetch_details error: %s", e)
            send_step(chat_id, f"执行 details 时发生异常：{e}")
            break

    try:
        if child.isalive():
            child.close(force=True)
    except Exception:
        pass

    output = clean_text("".join(chunks))
    logger.info("Details output:\n%s", output)
    return output


def create_and_fetch_card_details(amount: str, chat_id: int) -> tuple[str, str, str]:
    create_output = run_create_command(amount, chat_id, timeout=300)

    if is_not_logged_in(create_output):
        raise RuntimeError("__LOGIN_REQUIRED__")

    card_id = extract_card_id(create_output)
    if not card_id:
        raise RuntimeError(
            "已执行创建命令，但未能从输出中提取 Card ID。\n\n创建输出：\n" + create_output
        )

    send_step(chat_id, f"已提取 Card ID：{card_id}")

    details_output = fetch_details(card_id, chat_id)
    if not details_output:
        raise RuntimeError(f"已获取 Card ID {card_id}，但 details 命令没有返回内容。")

    return card_id, create_output, details_output


async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not update.message or not update.effective_user:
        return

    cleanup_expired_sessions()

    if not is_allowed_user(update.effective_user.id):
        await update.message.reply_text("无权限使用此机器人。")
        return

    await update.message.reply_text(
        "欢迎使用卡片机器人。\n发送 /create_cards 或 /create cards 开始。"
    )


async def create_cards(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not update.message or not update.effective_user:
        return

    cleanup_expired_sessions()

    if not is_allowed_user(update.effective_user.id):
        await update.message.reply_text("无权限使用此机器人。")
        return

    chat_id = update.effective_chat.id
    reset_session(chat_id)
    session = get_or_create_session(chat_id)
    session.stage = "waiting_amount"

    await update.message.reply_text("请输入预付卡金额")


async def cancel(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not update.message:
        return
    chat_id = update.effective_chat.id
    reset_session(chat_id)
    await update.message.reply_text("已取消当前流程。")


async def handle_text(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not update.message or not update.effective_user:
        return

    cleanup_expired_sessions()

    if not is_allowed_user(update.effective_user.id):
        await update.message.reply_text("无权限使用此机器人。")
        return

    chat_id = update.effective_chat.id
    text = update.message.text.strip()
    session = get_or_create_session(chat_id)

    try:
        if session.stage == "idle":
            if text == "/create cards":
                reset_session(chat_id)
                session = get_or_create_session(chat_id)
                session.stage = "waiting_amount"
                await update.message.reply_text("请输入预付卡金额")
            else:
                await update.message.reply_text("请发送 /create_cards 或 /create cards 开始。")
            return

        if session.stage == "waiting_amount":
            if not re.fullmatch(r"\d+(\.\d+)?", text):
                await update.message.reply_text("金额格式不正确，请输入数字，例如：1")
                return

            if not is_allowed_amount(text):
                if ALLOWED_AMOUNTS:
                    allowed = ", ".join(sorted(ALLOWED_AMOUNTS))
                    await update.message.reply_text(f"当前仅允许这些金额：{allowed}")
                else:
                    await update.message.reply_text("金额不允许。")
                return

            session.amount = text
            session.stage = "generating"
            await update.message.reply_text("正在处理，请稍候...")

            try:
                card_id, create_output, details_output = await asyncio.to_thread(
                    create_and_fetch_card_details, session.amount, chat_id
                )
            except RuntimeError as e:
                if str(e) == "__LOGIN_REQUIRED__":
                    await asyncio.to_thread(run_login_command, chat_id, AGENT_LOGIN_EMAIL)
                    session.stage = "waiting_login_confirm"
                    await update.message.reply_text(
                        f"检测到登录已过期。\n"
                        f"已自动输入登录邮箱：{AGENT_LOGIN_EMAIL}\n"
                        f"请去邮箱点击登录链接，完成后回复任意消息继续。"
                    )
                    return
                raise

            final_msg = format_details_message(card_id, details_output)
            if len(final_msg) > 3900:
                final_msg = final_msg[-3900:]

            await update.message.reply_text(final_msg, parse_mode="MarkdownV2")
            reset_session(chat_id)
            return

        if session.stage == "waiting_login_confirm":
            session.stage = "generating"
            await update.message.reply_text("收到，开始继续执行创建流程，请稍候...")

            card_id, create_output, details_output = await asyncio.to_thread(
                create_and_fetch_card_details, session.amount, chat_id
            )

            final_msg = format_details_message(card_id, details_output)
            if len(final_msg) > 3900:
                final_msg = final_msg[-3900:]

            await update.message.reply_text(final_msg, parse_mode="MarkdownV2")
            reset_session(chat_id)
            return

        if session.stage == "generating":
            await update.message.reply_text("当前正在处理，请勿重复提交。")
            return

        reset_session(chat_id)
        await update.message.reply_text("状态异常，已重置。")

    except Exception as e:
        logger.exception("处理消息时出错")
        msg = str(e)
        if len(msg) > 3500:
            msg = msg[-3500:]
        await update.message.reply_text(f"发生错误：\n{msg}")
        reset_session(chat_id)


async def error_handler(update: object, context: ContextTypes.DEFAULT_TYPE):
    logger.error("Exception while handling an update:", exc_info=context.error)


def main():
    global APP, MAIN_LOOP

    application = Application.builder().token(BOT_TOKEN).build()
    APP = application

    application.add_handler(CommandHandler("start", start))
    application.add_handler(CommandHandler("create_cards", create_cards))
    application.add_handler(CommandHandler("cancel", cancel))
    application.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_text))
    application.add_error_handler(error_handler)

    try:
        MAIN_LOOP = asyncio.get_event_loop()
    except RuntimeError:
        MAIN_LOOP = None

    application.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    main()
PYEOF

echo "==> 创建 Python 虚拟环境"
python3 -m venv "$APP_DIR/venv"

echo "==> 安装 Python 依赖"
"$APP_DIR/venv/bin/pip" install --upgrade pip
"$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt"

echo "==> 写入 systemd 服务"
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Telegram Agent Cards Bot Local
After=network.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/python $APP_DIR/bot.py
Restart=always
RestartSec=5
User=root
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

echo "==> 重载并启动服务"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

echo
echo "======================================"
echo "部署完成"
echo "服务名: $SERVICE_NAME"
echo "项目目录: $APP_DIR"
echo
echo "查看状态:"
echo "  systemctl status $SERVICE_NAME"
echo
echo "查看日志:"
echo "  journalctl -u $SERVICE_NAME -f"
echo
echo "重启服务:"
echo "  systemctl restart $SERVICE_NAME"
echo "======================================"
