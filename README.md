# Debian 13 VPS 安全初始化

用于新装 **Debian 13** VPS 的一键初始化脚本。它创建一个仅能使用 SSH 公钥登录的管理员用户、关闭 root 和密码登录、配置 SSH 加固、开启 Fail2ban，并可选发送 Telegram 提醒。

## 为什么不沿用原脚本

- 不使用 \`pip install fail2ban\` 或覆盖 systemd 服务。Debian 官方 \`fail2ban\` 包才与系统 Python、systemd 集成；pip 兜底会留下两套 Fail2ban，升级后容易失效。
- 不依赖 \`/var/log/auth.log\` 和 \`rsyslog\`，直接读取 systemd journal，适合 Debian 13 默认日志方式。
- 默认不允许 root SSH。脚本创建 \`admin\`（可改名）并授予仅在持有 SSH 私钥时才有意义的免密 sudo，不会出现禁用密码后 sudo 无法使用的问题。
- 不默认永久封禁。共享出口 IP、输错客户端配置时，永久封禁很容易把自己锁住。默认从一天开始，重复违规逐级延长、最多四周；确实需要永久封禁才使用 \`--permanent-bans\`。
- 写入 SSH 配置前会执行 \`sshd -t\` 和 \`sshd -T\`，重载后保留 10 分钟自动回滚。必须从新的终端成功登录后确认配置。

## 准备

1. 在**你的电脑**生成密钥（已有则跳过）：

   \`\`\`bash
   ssh-keygen -t ed25519 -a 64 -f ~/.ssh/vps_debian13
   \`\`\`

2. 在云厂商安全组 / 防火墙放行你选的端口，例如 \`52022/tcp\`。先保留 22，直到新连接已验证。

3. 将本仓库的 \`bootstrap.sh\` 上传到 VPS，或从 GitHub 下载。脚本要求 root/sudo；传入的是 \`.pub\` 公钥，绝不传私钥。

## 执行

最稳妥的方式是在 VPS 上先保存公钥文件，再执行：

\`\`\`bash
sudo bash bootstrap.sh \
  --public-key-file /root/vps_debian13.pub \
  --admin-user admin \
  --ssh-port 52022
\`\`\`

也可以直接传公钥（公钥不是秘密）：

\`\`\`bash
sudo bash bootstrap.sh --public-key "ssh-ed25519 AAAA...你的公钥... laptop"
\`\`\`

成功后，**不要关闭当前 SSH 窗口**。另开一个终端验证：

\`\`\`bash
ssh -i ~/.ssh/vps_debian13 -p 52022 admin@服务器IP
sudo /usr/local/sbin/vps-security-confirm
\`\`\`

若十分钟内没确认，脚本只会移除自己的 SSH drop-in 以恢复原 SSH 策略；用户和 Fail2ban 不会被删除。

## Telegram 提醒（可选）

先从 [@BotFather](https://t.me/BotFather) 创建 bot。让 bot 收到至少一条消息，然后访问下列接口取得 \`chat.id\`。不要公开包含 token 的命令、终端历史或截图。

\`\`\`bash
curl -s "https://api.telegram.org/bot<你的TOKEN>/getUpdates"
\`\`\`

不要把 token 放进命令参数（它可能留在 shell 历史或短暂出现在进程参数中）。在 VPS 上分别创建两个仅 root 可读的单行文件：


```bash
sudo install -m 600 /dev/null /root/tg-token
sudo install -m 600 /dev/null /root/tg-chat-id
sudoedit /root/tg-token
sudoedit /root/tg-chat-id
```

执行时增加：

\`\`\`bash
sudo bash bootstrap.sh \
  --public-key-file /root/vps_debian13.pub \
  --telegram-token-file /root/tg-token \
  --telegram-chat-id-file /root/tg-chat-id
\`\`\`

Telegram 凭据只存储于 VPS 的 \`/etc/vps-security/telegram.env\`，权限为 \`0600\`，不会进入此仓库。通知显示 IPv4 前两段（如 \`203.0.x.x\`）；IPv6 只保留前两个 hextet。成功 SSH 公钥登录和 Fail2ban 封禁都会提醒。

## 生效策略

| 项目 | 设置 |
| --- | --- |
| SSH 端口 | \`52022\`（可改） |
| SSH 用户 | 仅 \`admin\`（可改） |
| root SSH | 禁用 |
| 密码 / 键盘交互登录 | 禁用 |
| 公钥认证 | 强制 |
| SSH 转发、X11、隧道 | 禁用 |
| 最大认证失败 | 3 |
| Fail2ban | systemd journal + nftables，3 次/10 分钟 |
| 封禁时长 | 首次 1 天，递增，最多 4 周 |

脚本不会配置云厂商防火墙，也不会尝试限制某一个动态家庭 IP。如果有固定办公 IP，可加 \`--ignoreip '203.0.113.0/24'\`，但请谨慎：这意味着该网段不会被 Fail2ban 封禁。

## 维护与排查

\`\`\`bash
sudo sshd -t
sudo sshd -T | grep '^port '
sudo fail2ban-client status sshd
sudo fail2ban-client get sshd banip
sudo fail2ban-client set sshd unbanip 203.0.113.9
sudo journalctl -u fail2ban -e --no-pager
\`\`\`

SSH 配置文件是 \`/etc/ssh/sshd_config.d/99-vps-security-bootstrap.conf\`；每次运行前脚本都会在 \`/etc/vps-security/backups/\` 备份其管理的文件。

## 限制

- 只针对 Debian 13，假定 systemd 和 nftables 可用。
- \`AllowTcpForwarding no\` 会禁止 SSH 端口转发和 SOCKS 代理；若确实需要，应在验证安全需求后手动放开。
- Fail2ban 只能限制反复认证失败，不能替代系统更新、云防火墙、备份、最小化服务和私钥保护。
