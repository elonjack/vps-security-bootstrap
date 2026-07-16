# Debian 13 VPS 安全初始化

用于新装 **Debian 13** VPS 的 SSH 加固脚本。它创建仅能使用公钥登录的管理员账户、禁用 root 与 SSH 密码登录、启用 Fail2ban，并可选发送 Telegram 通知。

## 安全边界

- 只支持 Debian 13、systemd 和 nftables。
- 脚本会执行系统升级并启用 `unattended-upgrades`；请先确认维护窗口。
- 脚本不会自动重写主机或云厂商防火墙。未知的服务和既有规则下，自动设置默认拒绝策略可能导致断连；应在登录验证后按业务自行配置最小放行。
- Fail2ban 只能缓解认证暴力破解，不能替代备份、云安全组、最小化服务、补丁管理和私钥保护。

## 改进的安全策略

- SSH 配置写入 `00-vps-security-bootstrap.conf`，使其在常见镜像的后置 drop-in 前读取。
- 写入后不仅执行 `sshd -t`，还用 `sshd -T` 验证端口、root 登录、密码认证、公钥认证及 SSH 转发的最终有效值；不符合即不重载 SSH。
- 旧版的 `99-vps-security-bootstrap.conf` 会先备份后移除，防止重复 `Port` 配置。
- 默认要求管理员使用本地 sudo 密码。SSH 密码认证仍是关闭的。`--allow-nopasswd-sudo` 仅为明确接受风险的场景保留。
- Telegram 凭据只接受 root 可读文件，避免 token 出现在 shell 历史和进程参数中。
- 每次应用 SSH 变更均创建独立的 systemd 回滚单元；确认成功后会停止该单元。

## 准备

1. 在本机生成密钥（已有可跳过）：

   ```bash
   ssh-keygen -t ed25519 -a 64 -f ~/.ssh/vps_debian13
   ```

2. 在云安全组中先放行计划使用的 SSH 端口，例如 `52022/tcp`；保留 22，直到新登录已验证。

3. 在 VPS 上创建仅 root 可读的 sudo 密码文件。该密码不会启用 SSH 密码登录：

   ```bash
   sudo install -m 600 /dev/null /root/vps-admin-password
   sudoedit /root/vps-admin-password
   ```

4. 将已审阅且固定版本的 `bootstrap.sh` 上传到 VPS。绝不上传 SSH 私钥。

## 执行

```bash
sudo bash bootstrap.sh \
  --public-key-file /root/vps_debian13.pub \
  --admin-password-file /root/vps-admin-password \
  --admin-user admin \
  --ssh-port 52022
```

不要关闭当前 SSH 窗口。另开终端验证新连接：

```bash
ssh -i ~/.ssh/vps_debian13 -p 52022 admin@服务器IP
sudo /usr/local/sbin/vps-security-confirm
sudo shred -u /root/vps-admin-password
```

若 10 分钟内没有确认，脚本会恢复自身管理的 SSH drop-in。管理员账户和 Fail2ban 配置不会删除。

只有已评估私钥泄露风险时，才可改用免密 sudo：

```bash
sudo bash bootstrap.sh --public-key-file /root/vps_debian13.pub --allow-nopasswd-sudo
```

## Telegram（可选）

创建两个仅 root 可读的单行文件：

```bash
sudo install -m 600 /dev/null /root/tg-token
sudo install -m 600 /dev/null /root/tg-chat-id
sudoedit /root/tg-token
sudoedit /root/tg-chat-id
```

执行时附加：

```bash
--telegram-token-file /root/tg-token \
--telegram-chat-id-file /root/tg-chat-id
```

凭据写入 `/etc/vps-security/telegram.env`，权限为 `0600`。通知包含主机名、用户名与打码后的来源 IP。

## 生效策略

| 项目 | 设置 |
| --- | --- |
| SSH 端口 | `52022`（可改） |
| SSH 用户 | 仅 `admin`（可改） |
| root SSH | 禁用 |
| SSH 密码与键盘交互 | 禁用 |
| 公钥认证 | 强制 |
| SSH 转发、X11、隧道 | 禁用 |
| sudo | 默认要求本地密码 |
| Fail2ban | systemd journal + nftables；3 次/10 分钟 |
| 封禁时长 | 首次 1 天，递增，最多 4 周 |
| 系统更新 | 立即升级并启用自动安全更新 |

## 防火墙和维护

在确认新 SSH 登录后，配置云安全组和主机防火墙，仅允许 SSH 新端口以及实际使用的服务端口（例如 80/443）。不要假定更换 SSH 端口本身能提供实质防护。

常用检查：

```bash
sudo sshd -t
sudo sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|allowtcpforwarding) '
sudo fail2ban-client status sshd
sudo journalctl -u fail2ban -e --no-pager
sudo systemctl status unattended-upgrades
```

本工具的 SSH 配置位于 `/etc/ssh/sshd_config.d/00-vps-security-bootstrap.conf`；每次运行前会在 `/etc/vps-security/backups/` 保存受管文件的备份。
