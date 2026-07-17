# Debian VPS 安全初始化（Debian 12 / 13，root 专用）

这是 root 专用的交互式初始化脚本：只允许 `root` 使用 SSH 公钥登录，关闭 SSH 密码登录，启用 Fail2ban、自动安全更新和可选 Telegram 通知。脚本**不会创建新的 SSH 用户**。

适用范围：**Debian 12、Debian 13、systemd**。请在新 VPS，或你明确知道现有 SSH 配置可被替换的 VPS 上使用。

> 直接使用 root 的代价是：私钥一旦泄露，攻击者直接拥有最高权限。请为这台 VPS 使用专用、强口令保护的私钥，且不要共享。

## 只需这样运行

保持当前 root SSH 窗口不要关闭，在 VPS 执行：

```bash
curl -fsSLO https://raw.githubusercontent.com/elonjack/vps-security-bootstrap/main/bootstrap.sh
bash bootstrap.sh
```

脚本会等待你粘贴 SSH 公钥，不需要预先上传 `.pub` 文件，也不会要求创建管理员账号或 sudo 密码。

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
3. 可选填写 Fail2ban 白名单、立即系统更新和 Telegram 通知。
4. 查看摘要并输入 `YES`。
5. 脚本安装组件、将公钥加入 `/root/.ssh/authorized_keys`、只允许 root 公钥登录、启动 Fail2ban。

现有 root 公钥不会被清空，脚本只会补充你本次粘贴的公钥；原文件会备份到 `/etc/vps-security/backups/`。

## 完成后必须验证

脚本会创建 10 分钟的 SSH 自动回滚保护。请新开本地终端（不要关闭当前 root 窗口）测试：

```bash
ssh -i ~/.ssh/id_ed25519 -p 22 root@服务器IP
```

把端口改成向导里的值。登录成功后，在新连接中执行：

```bash
/usr/local/sbin/vps-security-confirm
```

这会取消自动回滚。若公钥或端口设置有误，10 分钟内没有确认时，脚本写入的 SSH 配置会自动还原。

## 最终 SSH 策略

- 仅允许 `root` 用户通过 SSH 登录。
- 仅允许公钥认证；SSH 密码和键盘交互登录均被禁用。
- 禁用 SSH 转发、X11、隧道等高风险功能。
- `PermitRootLogin yes` 只用于允许 root 公钥认证；由于同时强制 `AuthenticationMethods publickey` 和关闭密码认证，它不允许 root 使用 SSH 密码进入。

## Telegram 通知与 VPS 名称

启用 Telegram 后，向导会要求填写 VPS 名称，例如 `HK-01`。通知会显示名称、主机、root 登录来源 IP、时间，以及 Fail2ban 封禁信息。

同一个 Bot Token 可以用于多台 VPS 的**通知**，为每台机器使用不同名称即可。接收通知的聊天应仅包含可信成员，因为消息含有来源 IP。

如果收到不认识的 root 登录成功通知，应视为私钥或服务器可能失陷：先通过云控制台或另一条可信连接保留访问，撤销可疑公钥、检查 SSH 日志、轮换密钥；无法确认影响范围时建议从可信镜像重建。

## 封禁策略

- SSH 10 分钟内失败 3 次：开始递增封禁，初始 1 天，最高 4 周。
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
