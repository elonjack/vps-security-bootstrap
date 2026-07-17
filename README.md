# Debian VPS 安全初始化（Debian 12 / 13）

这是一个交互式的一键安全初始化脚本。它会创建一个新的管理员账号、只允许 SSH 公钥登录、关闭 root 和 SSH 密码登录、启用 Fail2ban 与自动安全更新。

适用范围：**Debian 12、Debian 13、systemd**。请在新 VPS，或你确认现有 SSH 配置可被替换的 VPS 上使用。

## 只需这样运行

先保持当前 SSH 窗口不要关闭，在 VPS 中执行：

```bash
curl -fsSLO https://raw.githubusercontent.com/elonjack/vps-security-bootstrap/main/bootstrap.sh
sudo bash bootstrap.sh
```

不用再事先上传 `.pub` 文件，也不用拼一长串参数。脚本会逐项提问并在真正修改前让你确认。

> 若系统没有 `curl`，可先执行 `sudo apt-get update && sudo apt-get install -y curl`，或者从仓库页面下载 `bootstrap.sh` 后运行 `sudo bash bootstrap.sh`。

## 运行前只准备一件事：SSH 公钥

如果你现在就是用 SSH 公钥登录 root，向导会自动发现它；直接选择“复用”即可。

如果你目前通过密码登录，在自己的电脑上生成密钥（已有密钥可跳过）：

```bash
ssh-keygen -t ed25519 -a 64
```

复制公钥内容，随后粘贴进向导：

```bash
cat ~/.ssh/id_ed25519.pub
```

**不要上传、粘贴或发送私钥**（没有 `.pub` 后缀的那个文件）。

## 向导会问什么

1. 管理员使用哪把 SSH 公钥：复用 root 现有公钥、直接粘贴，或读取服务器上的 `.pub` 文件。
2. 新管理员用户名，默认 `admin`。
3. SSH 端口。默认保持服务器当前端口（通常为 `22`），这样不会因为云厂商安全组未放行新端口而失联。
4. 固定管理 IP 是否加入 Fail2ban 白名单（没有可直接回车）。
5. 是否立即更新系统、是否启用 Telegram 通知（均可选）。
6. 确认摘要后，为新管理员设置 sudo 密码两次。这个密码**只用于 sudo，不会重新开启 SSH 密码登录**。

如果你改了 SSH 端口，必须先在云厂商安全组/防火墙中放行新端口；脚本也会再次要求确认。

## 完成后必须验证

脚本会保留 10 分钟的 SSH 自动回滚保护。请新开一个本地终端（不要关闭原 SSH 窗口）测试：

```bash
ssh -i ~/.ssh/id_ed25519 -p 22 admin@服务器IP
```

将 `22`、`admin` 改为你在向导中选的值。登录成功后执行：

```bash
sudo /usr/local/sbin/vps-security-confirm
```

这会取消回滚保护。若你因为公钥或端口设置错误而无法新登录，等待 10 分钟后，脚本写入的 SSH 配置会自动还原。

## 它实际做了什么

- 创建或更新指定管理员，并只授权所选 SSH 公钥。
- 禁止 root、SSH 密码和键盘交互登录；关闭 SSH 转发、X11、隧道等高风险功能。
- 使用 Fail2ban：10 分钟内失败 3 次会封禁，封禁会逐次延长，最长 4 周。
- 安装 OpenSSH、Fail2ban、nftables、sudo、unattended-upgrades，并启用 Debian 自动安全更新。
- 修改前备份自己管理的配置到 `/etc/vps-security/backups/`，并在重载 SSH 前验证最终生效配置。

脚本**不会**替你改云厂商安全组或清空现有防火墙规则；这类操作因环境不同容易造成断连，需要你自行确认。

## 自动化部署（可选）

批量部署仍可使用参数模式；此时不会进入向导：

```bash
sudo bash bootstrap.sh \
  --public-key-file /root/admin.pub \
  --admin-user admin \
  --ssh-port 22
```

非交互运行还应通过 `--admin-password-file /root/admin-password` 提供管理员 sudo 密码。该文件必须归 root 所有、权限为 `0600` 或更严格。Telegram 凭据也请使用 `--telegram-token-file` 与 `--telegram-chat-id-file`，不要出现在命令行历史中。

常用检查命令：

```bash
sudo sshd -t
sudo sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication) '
sudo fail2ban-client status sshd
sudo systemctl status unattended-upgrades
```
