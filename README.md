# VPS Security Bootstrap

[![Lint](https://github.com/elonjack/vps-security-bootstrap/actions/workflows/lint.yml/badge.svg)](https://github.com/elonjack/vps-security-bootstrap/actions/workflows/lint.yml)
[![Latest release](https://img.shields.io/github/v/release/elonjack/vps-security-bootstrap?display_name=tag)](https://github.com/elonjack/vps-security-bootstrap/releases/latest)

为 Debian 12/13 和 Windows 11 VPS 提供原生安全初始化向导。项目保留各系统最合适的脚本语言，但你只需要在自己的系统运行一条短安装命令。

> 这是安全初始化工具，不是安全保证。改端口只减少扫描噪声；云厂商安全组、强凭据、及时更新和可验证的恢复路径仍不可替代。

## 快速开始

安装器会下载**固定版本**的主脚本与 SHA-256 文件，校验通过后才启动安全向导。下列短命令本身通过 GitHub HTTPS 获取当前稳定版安装器；高价值 VPS 请使用后面的“固定版本完整校验”。

### Debian 12 / 13

以 root 登录，或具有 sudo 权限：

```bash
curl -fsSL https://github.com/elonjack/vps-security-bootstrap/releases/latest/download/install.sh | sudo bash
```

首次 Debian 加固会启用 nftables：默认拒绝所有入站，仅放行 SSH TCP 端口、已建立连接、回环和必要 ICMP/ICMPv6。网站、HY2、VPN 等服务端口请在后续的“nftables 防火墙操作”菜单中明确添加。

### Windows 11 Pro / Enterprise / Education

以“管理员身份”打开 Windows PowerShell：

```powershell
irm https://github.com/elonjack/vps-security-bootstrap/releases/latest/download/install.ps1 | iex
```

Windows 入口只在 Windows 11 运行，Debian 入口只在 Debian 12/13 运行；它们会拒绝错误系统，不会错误地执行另一套系统配置。

## 这不是两个要学的入口

底层必须分别使用 Bash 和 PowerShell：Debian 无法原生执行 `.ps1`，Windows 也无法执行 `bash <(...)`。把两种语言硬塞进一个“跨平台脚本”会降低可读性、审计性和兼容性。

因此项目采用两层结构：

| 你在什么系统 | 你运行什么 | 安装器做什么 |
| --- | --- | --- |
| Debian 12 / 13 | `install.sh` | 识别 Debian，下载并校验 `bootstrap.sh`，再启动 SSH 向导 |
| Windows 11 | `install.ps1` | 识别 Windows 11，下载并校验 `windows-bootstrap.ps1`，再启动 RDP 向导 |

你不需要手动下载主脚本；两个安装器只是各自平台的最短、最规范入口。

## 固定版本完整校验

对生产或高价值 VPS，建议先校验**安装器本身**，再执行。示例固定使用当前 `v1.3.1`。

### Debian

```bash
version=v1.3.1
base="https://github.com/elonjack/vps-security-bootstrap/releases/download/$version"
curl -fSLO "$base/install.sh"
curl -fSLO "$base/install.sh.sha256"
sha256sum --check install.sh.sha256
sudo bash install.sh
```

### Windows

```powershell
$version = 'v1.3.1'
$base = "https://github.com/elonjack/vps-security-bootstrap/releases/download/$version"
Invoke-WebRequest "$base/install.ps1" -OutFile install.ps1
Invoke-WebRequest "$base/install.ps1.sha256" -OutFile install.ps1.sha256
$expected = ((Get-Content .\install.ps1.sha256 -Raw) -split '\s+')[0]
$actual = (Get-FileHash .\install.ps1 -Algorithm SHA256).Hash
if ($actual -ne $expected) { throw 'SHA-256 校验失败，禁止运行。' }
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

安装器还会再次校验主脚本。Release 使用不可变保护：已发布的 tag 和附件不能被替换；但“latest”仍会在未来指向新版本，因此固定版本更适合需要变更控制的服务器。

## 功能概览

| 能力 | Debian 12 / 13 | Windows 11 |
| --- | --- | --- |
| 远程入口 | root SSH 公钥登录 | RDP |
| 端口 | 可设置 SSH 端口 | 可重复修改 RDP 端口 |
| 凭据防护 | 禁用密码与键盘交互认证 | NLA、TLS、高加密 |
| 主机防火墙 | nftables 默认拒绝入站；SSH 与明确配置的 TCP/UDP 端口 | Windows 防火墙固定 IP/CIDR 白名单 |
| 爆破缓解 | Fail2ban + recidive | RDP Guard + 账户短时锁定 |
| 来源限制 | Fail2ban 可信 IP/CIDR | Windows 防火墙固定 IP/CIDR 白名单 |
| Telegram | SSH 成功登录、Fail2ban 封禁 | RDP 成功登录、封禁、解封 |
| 回滚 | 关键文件备份 | 注册表、防火墙、策略、任务备份和 `restore.ps1` |

所有交互式标题、菜单和输入提示为黄色；成功为绿色、错误为红色。`[Y/n，回车=是]` 与 `[y/N，回车=否]` 会明确显示直接回车的默认动作。

## 使用前必读

1. 改 SSH/RDP 端口前，先在 VPS 厂商安全组或云防火墙放行新端口。Debian 还需要在本脚本的 nftables 菜单放行该端口。
2. 新连接验证成功前，保持当前 SSH/RDP 会话或厂商控制台打开。
3. 固定公网管理 IP 时，优先配置来源白名单；这比改端口更有效。
4. Telegram 是告警，不是阻止私钥泄露或账户接管的防线。
5. Debian 模式只保留 root 公钥登录。私钥一旦泄露即代表最高权限，请使用专用、强口令保护的私钥。

## Debian 12 / 13

向导会要求粘贴 `.pub` 公钥的一整行，只保留这把 root 公钥并关闭 SSH 密码、键盘交互、转发和隧道功能。它在写入后使用 `sshd -t` 与最终生效配置校验；Fail2ban 配置失败时会恢复本次修改前的配置。

首次部署会启用脚本专用的 `inet vps_security_bootstrap` nftables 表，默认拒绝入站；它不会执行 `nft flush ruleset`，因此不会清空 Fail2ban、Docker 或其他应用自己的规则表。初次仅放行 SSH TCP 端口。改 SSH 端口时会短暂同时放行旧/新端口，SSH 校验成功后自动仅保留新端口。

以后重新运行一键安装器并选择主菜单 `3. nftables 防火墙操作`，或直接执行以下命令，即可管理端口：

```bash
curl -fsSL https://github.com/elonjack/vps-security-bootstrap/releases/latest/download/install.sh \
  | sudo bash -s -- --firewall
```

该命令会下载、校验后临时运行主脚本；不会保留临时文件。菜单支持查看实际规则、更新额外 TCP/UDP 端口，以及恢复为仅 SSH。端口可使用单端口、连续范围、逗号组合；直接回车表示该协议不额外放行端口：

```text
TCP：80,443,51820
UDP：20000-20199
```

上例会放行网站 TCP 80/443、一个 TCP 服务端口，以及 UDP 连续 200 个端口。若 HY2 配置使用 UDP 跳跃端口范围，可在 UDP 项填写例如 `20000-20199`；不要为不需要的协议额外放行端口。云安全组和本机 nftables 都必须放行，服务才能从公网访问。

默认不会执行整机 `apt upgrade`，需要你明确确认。SSH 端口切换前会检查 TCP/UDP 监听冲突。

自动化时可保留安装器下载文件并传递主脚本参数：

```bash
curl -fsSL https://github.com/elonjack/vps-security-bootstrap/releases/latest/download/install.sh \
  | sudo bash -s -- --keep -- --public-key-file /root/root-login.pub --ssh-port 52022
```

## Windows 11

每次重新运行 Windows 向导都可以改 RDP 端口。改端口时，旧端口仅在重启前临时放行；一次性开机任务会在下次启动后自动删除旧规则，RDP Guard 在重启前同时保护新旧端口。

默认 RDP Guard 会在同一来源 5 分钟内出现 5 次相关失败时，封禁该来源 1 天；本地账户策略默认连续失败 10 次锁定 15 分钟。固定白名单最可靠；并发或多来源攻击仍可能先造成锁定。

Windows Telegram Token 隐藏输入，配置仅允许 `Administrators` 和 `SYSTEM` 访问。启用前必须成功发送测试消息；API 临时失败不会阻止封禁执行。

DD Windows 时，可在 [`bin456789/reinstall`](https://github.com/bin456789/reinstall) 的原有命令上加 `--rdp-port 52089`，让第一次启动就避开默认 3389；之后仍可用本项目向导再次更换端口。

## Telegram

先在 Telegram 创建 Bot，打开机器人并发送任意消息，再从 `getUpdates` 返回的 `message.chat.id` 获取数字 Chat ID。通知包含主机名、VPS 名称、来源 IP 和时间，请仅发送到可信聊天。

发现未知 root SSH 或 RDP 登录成功通知时，应按凭据泄露或主机失陷处理：保留访问路径、轮换密钥/密码、检查日志；无法确认影响范围时从可信镜像重建 VPS。

## 验证与回滚

Debian 完成后另开终端验证：

```bash
ssh -i ~/.ssh/id_ed25519 -p 你的端口 root@服务器IP
```

Windows 的备份位于 `C:\ProgramData\VpsSecurityBootstrap\backups\时间戳\`；需要回滚时从管理员会话执行其中的 `restore.ps1`。该恢复脚本会整体恢复备份时的 Windows 防火墙状态，因此只应使用紧邻本次修改的备份。

## Release 附件

每个正式 Release 提供：

- `install.sh` 与 `install.sh.sha256`
- `bootstrap.sh` 与 `bootstrap.sh.sha256`
- `install.ps1` 与 `install.ps1.sha256`
- `windows-bootstrap.ps1` 与 `windows-bootstrap.ps1.sha256`

## 开发与检查

GitHub Actions 检查 Bash 语法、ShellCheck、PowerShell 5.1 AST、PSScriptAnalyzer、内嵌 Windows 任务脚本、编码、版本一致性及 Git 空白错误。

策略依据：[Microsoft：更改 RDP 端口](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/remotepc/change-listening-port)、[NLA](https://learn.microsoft.com/en-in/windows-server/remote/remote-desktop-services/remotepc/remote-desktop-allow-access)、[成功登录事件 4624](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-10/security/threat-protection/auditing/event-4624)、[失败登录事件 4625](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-10/security/threat-protection/auditing/event-4625)、[Telegram Bot API](https://core.telegram.org/bots/api#sendmessage)。
