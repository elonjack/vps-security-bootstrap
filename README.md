# Debian VPS 安全初始化（Debian 12 / 13，root 专用）

这是 root 专用的交互式初始化脚本：只允许 `root` 使用 SSH 公钥登录，关闭 SSH 密码登录，启用 Fail2ban 和可选 Telegram 通知；系统更新仅在你最后确认时按选择执行一次。脚本**不会创建新的 SSH 用户**。

适用范围：**Debian 12、Debian 13、systemd**。请在新 VPS，或你明确知道现有 SSH 配置可被替换的 VPS 上使用。

> 直接使用 root 的代价是：私钥一旦泄露，攻击者直接拥有最高权限。请为这台 VPS 使用专用、强口令保护的私钥，且不要共享。

## 一键运行（最新稳定版）

以 root 登录 VPS 后直接执行：

```bash
bash <(curl -fsSL https://github.com/elonjack/vps-security-bootstrap/releases/latest/download/bootstrap.sh)
```

这会下载并运行最新的正式 Release，而不是可变的 `main` 分支。脚本会等待你粘贴 SSH 公钥，不需要预先上传 `.pub` 文件，也不会要求创建管理员账号或 sudo 密码。运行前请确认你信任本仓库；该命令会以 root 权限执行远程脚本。

从 `v1.0.10` 起，新发布的 Release 会启用 GitHub 不可变保护：公开后其附件和 tag 不能被修改或删除。

## 固定版本运行（可选）

如果你希望始终运行某个确切版本，而不是以后自动更新到最新 Release，例如固定使用当前的 `v1.1.3`：

```bash
bash <(curl -fsSL https://github.com/elonjack/vps-security-bootstrap/releases/download/v1.1.3/bootstrap.sh)
```

以后发布新版本后，如需固定使用新版，只需把命令中的版本号改为对应的新版本号。


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
3. 可选填写 Fail2ban 白名单、是否执行系统更新和 Telegram 通知；所有 `[y/N]` 确认项直接回车均为“否”，必须输入 `y` 才会同意；此时仅记录选择，尚未修改系统。
4. 查看摘要并确认执行；此项默认“否”，请输入 `y` 后回车才会开始修改系统。
5. 脚本安装组件、用本次公钥覆盖 `/root/.ssh/authorized_keys`、禁用其他 root 公钥来源、只允许 root 公钥登录、启动 Fail2ban。

`/root/.ssh/authorized_keys` 只保留本次粘贴的这一把公钥。脚本只允许 SSH 从这个文件读取 root 公钥，并禁用额外的授权密钥命令和用户 CA；遗留的 `/root/.ssh/authorized_keys2` 会在备份后移除。原文件会备份到 `/etc/vps-security/backups/`。

## 完成后必须验证

请新开本地终端测试，但在验证成功前不要关闭当前 root SSH 窗口：

```bash
ssh -i ~/.ssh/id_ed25519 -p 22 root@服务器IP
```

把端口改成向导里的值。新连接成功后，新 SSH 配置即已生效，可以关闭旧窗口。本工具不创建自动回滚任务；若新连接失败，请用仍保持打开的旧 SSH 会话排查配置，或使用云厂商控制台/重装系统恢复访问。

## 最终 SSH 策略

- 仅允许 `root` 用户通过 SSH 登录。
- 仅允许公钥认证；SSH 密码和键盘交互登录均被禁用。
- root 公钥只从 `/root/.ssh/authorized_keys` 读取；`authorized_keys2`、`AuthorizedKeysCommand` 和用户 CA 均被禁用。
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
5. 在脚本中粘贴 Token、Chat ID，并填写 VPS 名称，例如 `HK-01`。粘贴 Token 后，终端不会显示任何字符、星号或长度；这是正常的安全保护，直接按回车即可。Chat ID 会正常显示。

通知会显示名称、主机、root 登录来源 IP、时间，以及 Fail2ban 封禁信息。

同一个 Bot Token 可以用于多台 VPS 的**通知**，为每台机器使用不同名称即可。接收通知的聊天应仅包含可信成员，因为消息含有来源 IP。

如果收到不认识的 root 登录成功通知，应视为私钥或服务器可能失陷：先通过云控制台或另一条可信连接保留访问，撤销可疑公钥、检查 SSH 日志、轮换密钥；无法确认影响范围时建议从可信镜像重建。

## 更换 Telegram Bot Token

已经启用 Telegram 通知的 VPS，如需作废旧 Token 或更换机器人 Token，重新下载并运行本脚本后，在第一个菜单选择 `2. 更换 Telegram Bot Token`。该操作会隐藏输入的新 Token，默认保留原 Chat ID 和 VPS 名称；确认更新后，仅原子更新 `/etc/vps-security/telegram.env` 并发送测试通知，**不会修改 SSH、公钥、端口、Fail2ban 或系统软件包**。

如果你已把脚本保存到 VPS，也可直接执行：

```bash
bash bootstrap.sh --rotate-telegram-token
```

新 Token 已保存但测试通知失败时，脚本会给出警告；请核对 Token、Chat ID、网络，以及是否已在对应机器人聊天中点击 **Start**。

## 封禁策略

- SSH 在 3 分钟内失败 3 次：立即封禁来源 IP；首次封禁 1 天，之后逐级延长，最高 4 周。这是偏严格的策略，适合仅用 SSH 私钥、且能通过云控制台恢复的 VPS。
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

Telegram 凭据文件必须归 root 所有、权限为 `0600` 或更严格；不要把 Token 放进命令行历史。 脚本向 Telegram 发送通知时，会经由 root 进程的标准输入传递 API 地址，不会把 Token 放入 `curl` 命令行参数。

常用检查命令：

```bash
sshd -t
sshd -T | grep -E '^(port|permitrootlogin|allowusers|passwordauthentication|pubkeyauthentication) '
fail2ban-client status sshd
fail2ban-client status recidive
```
