安装：
chmod +x install_telegram_card_bot_local.sh
sudo bash install_telegram_card_bot_local.sh
卸载：
systemctl stop telegram-card-bot 2>/dev/null || true
systemctl disable telegram-card-bot 2>/dev/null || true
rm -f /etc/systemd/system/telegram-card-bot.service
systemctl daemon-reload
systemctl reset-failed
rm -rf /opt/telegram-card-bot
首次请手动执行
agent-cards cards create --amount 1
输入姓名 出生日期 手机号
保存完毕后即可会自动保存即可直接使用
在Telegram执行：/create_cards
