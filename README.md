# Debian VPS 安全初始化（Debian 12 / 13，root 专用）

这是 root 专用的交互式初始化脚本：只允许 `root` 使用 SSH 公钥登录，关闭 SSH 密码登录，启用 Fail2ban、自动安全更新和可选 Telegram 通知。脚本**不会创建新的 SSH 用户**。

适用范围：**Debian 12、Debian 13、systemd**。请在新 VPS，或你明确知道现有 SSH 配置可被替换的 VPS 上使用。

> 直接使用 root 的代价是：私钥一旦泄露，攻击者直接拥有最高权限。请为这台 VPS 使用专用、强口令保护的私钥，且不要共享。

## 安全获取并运行

不要下载可变的 `main` 分支后直接以 root 执行。请从 [Releases](https://github.com/elonjack/vps-security-bootstrap/releases) 下载指定版本的 `bootstrap.sh` 和对应的 `bootstrap.sh.sha256`，校验通过后再运行。

```bash
VERSION='替换为发布版本，例如 v1.0.0'
curl -fLO "https://github.com/elonjack/vps-security-bootstrap/releases/download/$VERSION/bootstrap.sh"
curl -fLO "https://github.com/elonjack/vps-security-bootstrap/releases/download/$VERSION/bootstrap.sh.sha256"
sha256sum -c bootstrap.sh.sha256
sudo bash bootstrap.sh
```

校验输出必须为 `bootstrap.sh: OK`。脚本会等待你粘贴 SSH 公钥，不需要预先上传 `.pub` 文件，也不会要求创建管理员账号或 sudo 密码。

## 如何准备并粘贴公钥

在**你自己的电脑**生成密钥（已有专用密钥可跳过）：

```bash
ssh-keygen -t ed25519 -a 64
cat ~/.ssh/id_ed25519.pub
```

第二条命令会显示一整行文本，例如：

```text
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... your-computer
```

运行脚本后，出现 `root SSH 公钥：` 时，把这一整行粘贴进去并按回车。**只能粘贴 `.pub` 文件内容；绝不能粘贴私钥 `id_ed25519`。**

Windows PowerShell 可用：

```powershell
Get-Content $HOME\.ssh\id_ed25519.pub
```

## 向导流程

1. 粘贴 root 的 SSH 公钥。
2. 选择 SSH 端口；默认保持当前端口，避免云安全组未放行新端口时失联。
3. 可选填写 Fail2ban 白名单、是否执行系统更新和 Telegram 通知；此时仅记录选择，尚未修改系统。
4. 查看摘要并输入 `YES`。
5. 脚本安装组件、用本次公钥覆盖 `/root/.ssh/authorized_keys`、只允许 root 公钥登录、启动 Fail2ban。

`/root/.ssh/authorized_keys` 只保留本次粘贴的这一把公钥；此前可登录 root 的其他公钥会失效。原文件会备份到 `/etc/vps-security/backups/`。

## 完成后必须验证

请新开本地终端测试，但在验证成功前不要关闭当前 root SSH 窗口：

```bash
ssh -i ~/.ssh/id_ed25519 -p 22 root@服务器IP
```

把端口改成向导里的值。新连接成功后，新 SSH 配置即已生效，可以关闭旧窗口。本工具不创建自动回滚任务；若新连接失败，请用仍保持打开的旧 SSH 会话排查配置，或使用云厂商控制台/重装系统恢复访问。

## 最终 SSH 策略

- 仅允许 `root` 用户通过 SSH 登录。
- 仅允许公钥认证；SSH 密码和键盘交互登录均被禁用。
- 禁用 SSH 转发、X11、隧道等高风险功能。
- `PermitRootLogin yes` 只用于允许 root 公钥认证；由于同时强制 `AuthenticationMethods publickey` 和关闭密码认证，它不允许 root 使用 SSH 密码进入。

## Fail2ban 白名单与防火墙

向导中的 Fail2ban 白名单可直接回车留空；这表示不为任何公网地址添加白名单。白名单不是 SSH 登录白名单：即使不填写，持有正确私钥仍可正常登录。只有固定管理出口确实可能因多次失败登录而被误封时，才填写 IP 或 CIDR，例如 `203.0.113.10`、`203.0.113.0/24` 或 `2001:db8::/64`。多个条目使用英文逗号分隔，脚本会拒绝非法格式、空格和换行。

脚本安装并使用 `nftables`，但用途是让 Fail2ban 封禁爆破来源；它不会设置“默认拒绝入站”的全局主机防火墙策略。请在云厂商安全组/防火墙中仅放行实际需要的端口，例如 SSH 端口，以及部署 Web 服务时的 80/443。

## Telegram 通知与 VPS 名称

启用 Telegram 前，先完成以下步骤：

1. 在 Telegram 搜索 `@BotFather`，发送 `/newbot` 并按提示创建机器人。
2. 保存 BotFather 返回的 HTTP API Token；它相当于机器人密码，不能分享。
3. 打开新建的机器人，点击 **Start** 并发送任意一条消息。
4. 在可信设备浏览器访问 `https://api.telegram.org/bot<你的Token>/getUpdates`，从返回内容的 `message.chat.id` 复制数字 Chat ID。
5. 在脚本中粘贴 Token、Chat ID，并填写 VPS 名称，例如 `HK-01`。Token 输入时不会回显。

通知会显示名称、主机、root 登录来源 IP、时间，以及 Fail2ban 封禁信息。

同一个 Bot Token 可以用于多台 VPS 的**通知**，为每台机器使用不同名称即可。接收通知的聊天应仅包含可信成员，因为消息含有来源 IP。

如果收到不认识的 root 登录成功通知，应视为私钥或服务器可能失陷：先通过云控制台或另一条可信连接保留访问，撤销可疑公钥、检查 SSH 日志、轮换密钥；无法确认影响范围时建议从可信镜像重建。

## 封禁策略

- SSH 在 10 分钟内失败 3 次：立即封禁来源 IP；首次封禁 1 天，之后逐级延长，最高 4 周。这是偏严格的策略，适合仅用 SSH 私钥、且能通过云控制台恢复的 VPS。
- 同一 IP 在 30 天内累计触发 5 次完整封禁：`recidive` jail 永久封禁该 IP 的所有端口。

## 自动化部署（可选）

```bash
bash bootstrap.sh \
  --public-key-file /root/root-login.pub \
  --ssh-port 22
```

Telegram 自动化参数：

```bash
--telegram-token-file /root/tg-token \
--telegram-chat-id-file /root/tg-chat-id \
--telegram-vps-name 'HK-01'
```

Telegram 凭据文件必须归 root 所有、权限为 `0600` 或更严格；不要把 Token 放进命令行历史。

常用检查命令：

```bash
sshd -t
sshd -T | grep -E '^(port|permitrootlogin|allowusers|passwordauthentication|pubkeyauthentication) '
fail2ban-client status sshd
fail2ban-client status recidive
```
