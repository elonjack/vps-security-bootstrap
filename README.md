# Debian VPS 安全初始化（Debian 12 / 13）

这是给新 VPS 用的 SSH 安全初始化脚本。它会创建一个只能用 SSH 公钥登录的管理员、关闭 root 和 SSH 密码登录、启用 Fail2ban，并开启系统安全更新。

适用：**Debian 12、Debian 13、systemd**。请在全新或你清楚现有 SSH 设置的 VPS 上使用。

## 运行前，先做这 3 件事

1. 在自己的电脑生成 SSH 密钥（已有密钥可跳过）：

   ```bash
   ssh-keygen -t ed25519 -a 64 -f ~/.ssh/my_vps
   ```

   会生成私钥 `~/.ssh/my_vps` 和公钥 `~/.ssh/my_vps.pub`。**私钥永远不要上传或发送给别人。**

2. 在云厂商防火墙/安全组中放行你要用的 SSH 端口，例如 `52022/tcp`。同时先保留默认 `22/tcp`，直到新登录测试成功。

3. 将 `my_vps.pub` 和本仓库的 `bootstrap.sh` 上传到 VPS。例如从你的电脑执行：

   ```bash
   scp ~/.ssh/my_vps.pub root@服务器IP:/root/my_vps.pub
   scp bootstrap.sh root@服务器IP:/root/bootstrap.sh
   ```

   如果已经把 `bootstrap.sh` 下载到 VPS，只需确保公钥文件在 `/root/my_vps.pub`。

## 一条命令执行

先保持当前 SSH 窗口不要关闭，在 VPS 运行：

```bash
sudo bash /root/bootstrap.sh \
  --public-key-file /root/my_vps.pub \
  --admin-user admin \
  --ssh-port 52022
```

脚本会要求你输入两次 **sudo 密码**。它只用于执行 `sudo`，不会开启 SSH 密码登录。

脚本会：更新系统、安装 OpenSSH/Fail2ban、创建 `admin`、写入 SSH 加固配置、启动 Fail2ban，并创建 10 分钟 SSH 自动回滚保护。

## 必须验证并确认

在**新的本机终端**测试，不要关闭原 SSH 窗口：

```bash
ssh -i ~/.ssh/my_vps -p 52022 admin@服务器IP
```

进入成功后执行：

```bash
sudo /usr/local/sbin/vps-security-confirm
```

这会取消自动回滚。若 10 分钟内没有确认，脚本只恢复它写入的 SSH 配置，避免因端口或密钥问题失去访问权限。

## 常用选项

| 需求 | 参数 |
| --- | --- |
| 改 SSH 端口 | `--ssh-port 2222` |
| 改管理员名 | `--admin-user alice` |
| 自动化运行，不想交互输入 sudo 密码 | `--admin-password-file /root/admin-password` |
| 明确接受私钥失窃即可 root 的风险 | `--allow-nopasswd-sudo` |
| 暂时跳过本次系统升级 | `--skip-system-upgrade` |
| 不创建 SSH 自动回滚 | `--no-rollback`（不推荐） |
| 对某固定办公 IP 不执行 Fail2ban 封禁 | `--ignoreip '203.0.113.0/24'` |

`--admin-password-file` 必须由 root 所有，权限必须为 `0600` 或更严格。创建示例：

```bash
sudo install -m 600 /dev/null /root/admin-password
sudoedit /root/admin-password
```

## Telegram 通知（可选）

准备两个仅 root 可读的单行文件：

```bash
sudo install -m 600 /dev/null /root/tg-token
sudo install -m 600 /dev/null /root/tg-chat-id
sudoedit /root/tg-token
sudoedit /root/tg-chat-id
```

然后在运行命令后增加：

```bash
--telegram-token-file /root/tg-token \
--telegram-chat-id-file /root/tg-chat-id
```

不要把 Telegram token 放到命令行、聊天记录或截图里。

## 脚本实际设置了什么

- 仅允许指定管理员通过 SSH 公钥登录。
- 禁止 root、SSH 密码、键盘交互登录，以及 SSH 转发、X11、隧道。
- SSH 登录失败 3 次后由 Fail2ban 封禁；默认封禁从 1 天开始逐次延长，最多 4 周。
- 启用 Debian 自动安全更新；使用 `--skip-system-upgrade` 只跳过这次立即升级，不关闭自动更新。
- 每次运行都会备份它管理的文件到 `/etc/vps-security/backups/`。

## 仍需要你自己做的事

- 在云安全组和主机防火墙中，仅开放 SSH 新端口和实际业务端口（如 80/443）。脚本不会擅自覆盖你的防火墙规则。
- 为 VPS 配置备份；Fail2ban 不能替代备份。
- 妥善保存私钥；丢失私钥或服务器控制台访问权会造成恢复困难。

常用检查命令：

```bash
sudo sshd -t
sudo sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication) '
sudo fail2ban-client status sshd
sudo systemctl status unattended-upgrades
```
