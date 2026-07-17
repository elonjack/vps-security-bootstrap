# Debian VPS 安全初始化（Debian 12 / 13）

交互式的一键安全初始化脚本：创建管理员、仅允许 SSH 公钥登录、关闭 root 与 SSH 密码登录、启用 Fail2ban、自动安全更新，以及可选的 Telegram 通知。

适用范围：**Debian 12、Debian 13、systemd**。请在新 VPS，或你确认现有 SSH 配置可被替换的 VPS 上使用。

## 只需这样运行

保持当前 SSH 窗口不要关闭，在 VPS 执行：

```bash
curl -fsSLO https://raw.githubusercontent.com/elonjack/vps-security-bootstrap/main/bootstrap.sh
sudo bash bootstrap.sh
```

脚本会进入中文向导，不必提前上传 `.pub` 文件，也不用拼一长串参数。

> 没有 `curl` 时，可先运行 `sudo apt-get update && sudo apt-get install -y curl`，或下载 `bootstrap.sh` 后运行 `sudo bash bootstrap.sh`。

## 运行前只准备 SSH 公钥

若你当前已通过 SSH 公钥登录 root，向导会发现它，选择“复用”即可。

若你当前用密码登录，在自己的电脑生成密钥（已有可跳过）：

```bash
ssh-keygen -t ed25519 -a 64
cat ~/.ssh/id_ed25519.pub
```

把第二条命令显示的一整行**公钥**粘贴到向导。不要上传、发送或粘贴私钥（没有 `.pub` 后缀的文件）。

## 向导会问什么

1. 管理员使用哪把 SSH 公钥：复用 root 现有公钥、直接粘贴，或读取服务器上的 `.pub` 文件。
2. 新管理员用户名，默认 `admin`。
3. SSH 端口。默认保持当前端口（通常是 `22`），避免云安全组未放行新端口时失联。
4. Fail2ban 白名单（固定管理 IP，没有可直接回车）。
5. 是否立即更新系统、是否启用 Telegram。
6. 确认摘要后，为管理员设置 sudo 密码两次；它**不会**开启 SSH 密码登录。

改 SSH 端口前，必须先在云厂商安全组/防火墙中放行新端口；脚本会再次确认。

## Telegram 通知与 VPS 名称

启用 Telegram 后，向导会要求填写一个 VPS 名称，例如 `HK-01`、`东京-博客`。每条通知会以该名称置顶，包含主机、用户、来源 IP、封禁时长与历史封禁次数，方便一个聊天同时观察多台服务器。

**同一个 Bot Token 可以用于多台 VPS 的通知**：为每台机器设置不同名称即可。请确保接收通知的聊天仅对可信成员开放，因为通知包含来源 IP。

### Telegram 按钮封禁（可选）

登录成功和自动封禁通知下方可以显示“🚫 封禁此 IP”。点击后可选择：**1 分钟、1 小时、1 天、1 周、永久**。按钮操作同时校验接收聊天和你配置的 Telegram 用户数字 ID；手动封禁只阻断该 IP 对本机 SSH 端口的访问。

登录成功通知中的 IP 可能正是你自己；没有控制台或其他可用网络出口时，不要误点自己的来源 IP。

这个模式有一条重要限制：**启用按钮控制的 Bot Token 必须专供这一台 VPS。** Telegram 的 `getUpdates` 回调队列由同一个 Bot 全局共享；同一 Token 被多台 VPS 同时轮询会发生抢消息，按钮无法可靠路由到正确的服务器。

因此：

- 多台 VPS 共用一个 Bot：选择“仅通知”，不要启用按钮控制。
- 每台 VPS 使用独立 Bot Token、但发送到同一个 Telegram 聊天：可以为每台启用按钮控制。
- 想要“一个 Bot 控制多台 VPS”：需要独立的集中式 Webhook/控制器，本脚本不会伪造一个不可靠的实现。

启用按钮控制时，向导会要求确认 Bot 专用，并输入允许操作的 Telegram 用户数字 ID。不要在群组中把该 Bot 的管理权限交给不可信成员。

## 封禁策略

- SSH 登录失败 3 次/10 分钟：开始递增封禁，初始 1 天，随后逐步延长，最高 4 周。
- 同一 IP 在 **30 天内累计触发 5 次完整封禁**：`recidive` jail 将对该 IP **永久封禁所有端口**。
- Telegram 手动封禁可自行选择时长或永久封禁，只影响 SSH 端口。

不把每次爆破都永久封禁，是为了降低动态公网 IP、误输密码或共享出口地址造成的长期误伤；对持续反复攻击者则会自动升级为永久封禁。

## 完成后必须验证

脚本保留 10 分钟 SSH 自动回滚保护。请新开一个本地终端（不要关闭原 SSH 窗口）测试：

```bash
ssh -i ~/.ssh/id_ed25519 -p 22 admin@服务器IP
```

将端口与用户名改为向导中的值。成功登录后执行：

```bash
sudo /usr/local/sbin/vps-security-confirm
```

这会取消回滚保护。若公钥或端口有误导致无法新登录，10 分钟后脚本写入的 SSH 配置会自动还原。

## 它实际做了什么

- 创建或更新指定管理员，并只授权所选 SSH 公钥。
- 禁止 root、SSH 密码、键盘交互登录，以及 SSH 转发、X11、隧道。
- 使用 nftables 后端的 Fail2ban，启用递增封禁和针对持续攻击者的永久 `recidive` 封禁。
- 安装 OpenSSH、Fail2ban、nftables、curl、jq、sudo、unattended-upgrades，并启用 Debian 自动安全更新。
- 备份本工具管理的配置到 `/etc/vps-security/backups/`，并在重载 SSH 前验证最终生效配置。

脚本不会修改云厂商安全组或清空现有防火墙规则；这类操作因环境不同容易造成断连，需要你自行确认。

## 自动化部署（可选）

带参数运行不会进入向导：

```bash
sudo bash bootstrap.sh \
  --public-key-file /root/admin.pub \
  --admin-user admin \
  --ssh-port 22 \
  --admin-password-file /root/admin-password
```

Telegram 自动化参数：

```bash
--telegram-token-file /root/tg-token \
--telegram-chat-id-file /root/tg-chat-id \
--telegram-vps-name 'HK-01'
```

专用 Bot 才可额外添加：

```bash
--telegram-control --telegram-admin-user-id 123456789
```

密码和 Telegram 凭据文件必须归 root 所有、权限为 `0600` 或更严格；不要把它们放进命令行历史。

常用检查命令：

```bash
sudo sshd -t
sudo fail2ban-client status sshd
sudo fail2ban-client status recidive
# 仅在启用 Telegram 按钮控制时运行：
sudo fail2ban-client status manual-telegram
sudo systemctl status vps-security-telegram-control
```
