# VPS Security Bootstrap

[![Lint](https://github.com/elonjack/vps-security-bootstrap/actions/workflows/lint.yml/badge.svg)](https://github.com/elonjack/vps-security-bootstrap/actions/workflows/lint.yml)
[![Latest release](https://img.shields.io/github/v/release/elonjack/vps-security-bootstrap?display_name=tag)](https://github.com/elonjack/vps-security-bootstrap/releases/latest)

适用于 Debian 12/13 与 Windows 11 VPS 的交互式安全初始化工具。两种系统使用各自原生的解释器：Debian 用 Bash，Windows 用 PowerShell；运行后只会显示当前系统能执行的菜单。

> 这不是安全保证。修改端口只能减少扫描噪声；云厂商安全组、强凭据、定期维护和保留可访问的控制台同样重要。

## 一键运行

### Debian 12 / 13

以 **root** 登录时运行：

```bash
bash <(curl -fsSL https://github.com/elonjack/vps-security-bootstrap/releases/latest/download/install.sh)
```

若使用普通 sudo 用户，运行：

```bash
curl -fsSL https://github.com/elonjack/vps-security-bootstrap/releases/latest/download/install.sh | sudo bash
```

### Windows 11 Pro / Enterprise / Education

用“管理员身份”打开 Windows PowerShell 后运行：

```powershell
irm https://github.com/elonjack/vps-security-bootstrap/releases/latest/download/install.ps1 | iex
```

安装器会下载固定版本的主脚本和 SHA-256 文件，校验通过后才启动向导。Debian 安装器只接受 Debian 12/13；Windows 安装器只接受 Windows 11。

## 开始前必须做的事

1. 改 SSH 或 RDP 端口前，先在 VPS 厂商安全组/云防火墙放行新端口。
2. 修改远程端口后，不要立即关闭当前 SSH/RDP 会话；另开窗口确认新端口可连接。
3. 固定公网管理 IP 时，优先使用来源白名单；它比改端口更有效。

## Debian 菜单说明

启动后输入相应数字；`0` 始终表示退出且不修改系统。

| 主菜单 | 会做什么 | 不会做什么 / 注意事项 |
| --- | --- | --- |
| `1. 初次部署 / 重新加固 SSH` | 替换 root 的 SSH 公钥、设置 SSH 端口、关闭密码和键盘交互登录、关闭转发/隧道、配置 Fail2ban，并启用本项目管理的 nftables 防火墙。 | 旧 root 公钥会失效；改端口前先放行云安全组，保留当前 SSH 会话。 |
| `2. 更换 Telegram Bot Token` | 更新 Telegram Token、Chat ID 和 VPS 名称；用于 SSH 登录成功和 Fail2ban 封禁通知。 | 不会修改 SSH、公钥、端口、Fail2ban 策略或防火墙。 |
| `3. nftables 防火墙操作` | 进入防火墙子菜单，管理本项目的入站放行端口。 | 不会修改 SSH 公钥或 Fail2ban。网站、HY2、VPN 等端口必须在这里明确放行。 |
| `0. 退出` | 不做任何修改。 | — |

选择 `1` 后，向导会依次询问以下内容；所有修改会在最后确认后才执行。

| 项目 | 作用 |
| --- | --- |
| root SSH 公钥 | 粘贴 `.pub` 文件的一整行；只保留这把公钥。绝不能粘贴私钥。 |
| SSH 端口 | 直接回车保留当前端口；改端口时脚本暂时放行新旧端口，SSH 重载成功后旧端口不再接受新连接。 |
| Fail2ban 白名单 | 可填可信 IP/CIDR；正常使用私钥登录不需要加白名单。 |
| `apt upgrade` | 默认不执行；确认后才安装系统可用更新。安装脚本依赖仍会执行 `apt update`。 |
| Telegram 通知 | 可选；Token 隐藏输入，配置成功后通知 SSH 登录与封禁事件。 |

### Debian 防火墙子菜单

| 子菜单 | 作用 |
| --- | --- |
| `1. 查看放行端口和实际生效规则` | 查看本项目保存的 TCP/UDP 端口和当前 nftables 规则。 |
| `2. 设置额外 TCP 放行端口` | 放行网站或 TCP 服务，例如 `80,443,51820`；直接回车清空额外 TCP 端口。 |
| `3. 设置额外 UDP 放行端口` | 放行 HY2/VPN 等 UDP 服务，例如 `20000-20199`；直接回车清空额外 UDP 端口。 |
| `4. 启用本脚本管理的防火墙` | 保留当前额外端口，启用“默认拒绝入站”。 |
| `5. 恢复为仅放行 SSH 端口` | 清空额外 TCP/UDP 端口，只保留 SSH。 |
| `6. 停用本脚本管理的防火墙` | 删除本项目的规则表和启动项；不会停止 nftables 服务，不会清空 Docker、Fail2ban 或其他程序的规则。 |
| `7. 重新加载本脚本管理的防火墙` | 只校验并重载本项目规则，不重启 nftables 服务。 |
| `0. 返回主菜单` | 不修改防火墙。 |

要直接进入防火墙菜单：

```bash
bash <(curl -fsSL https://github.com/elonjack/vps-security-bootstrap/releases/latest/download/install.sh) --firewall
```

## Windows 11 菜单说明

以管理员身份运行后，输入相应数字；`0` 表示退出且不修改系统。

| 主菜单 | 会做什么 | 你需要注意的事 |
| --- | --- | --- |
| `1. 应用或更新 Windows 11 RDP 安全防护` | 配置 RDP、Windows 防火墙、可选来源白名单、RDP Guard、账户锁定策略和 Telegram。 | 修改前会备份注册表、防火墙、策略和计划任务；RDP 端口要在重启后完全生效。 |
| `2. 查看当前 Windows 11 安全状态` | 显示 RDP 端口、NLA、防火墙、RDP Guard、Telegram 与自动更新状态。 | 只读，不修改系统。 |
| `3. 更换 Telegram Bot Token 或通知目标` | 更新 RDP 登录、封禁、解封通知的 Token、Chat ID 与 VPS 名称。 | 不修改 RDP、端口、防火墙或账户策略。 |
| `4. Windows Update 自动更新控制` | 查看、禁用或恢复 Windows 自动更新。 | 适合磁盘很小的 VPS；禁用更新会降低安全性，应自行安排手动更新。 |
| `0. 退出` | 不做任何修改。 | — |

选择 `1` 后，各项配置的作用如下：

| 项目 | 作用 |
| --- | --- |
| RDP 端口 | 可改为 1024–65535 的未占用端口。重启前旧端口临时放行，重启后自动移除旧规则。 |
| 来源白名单 | 填固定公网 IP/CIDR 后，只有这些来源能访问 RDP；动态 IP 请选 `Any`。 |
| NLA / TLS / 高加密 | 强制网络级身份验证、TLS 安全层和高加密，同时关闭远程协助。 |
| Windows 防火墙 | 启用全部配置文件并默认拒绝入站，只允许配置的 RDP TCP/UDP 端口和来源。 |
| RDP Guard | 可选。默认同一来源 5 分钟内失败 5 次，封禁 1 天。 |
| 账户锁定策略 | 可选。默认连续失败 10 次锁定 15 分钟。 |
| Telegram | 可选；Token 仅允许 `Administrators` 和 `SYSTEM` 访问，启用前必须成功发送测试消息。 |

选择 `4` 后的子菜单：

| 子菜单 | 作用 |
| --- | --- |
| `1. 禁用 Windows 自动更新` | 写入 `NoAutoUpdate=1` 策略，停止并禁用 `wuauserv` 服务；执行前创建可恢复备份。 |
| `2. 恢复 Windows 默认更新行为` | 移除本脚本写入的策略，并将 Windows Update 服务改回按需启动。 |
| `0. 返回主菜单` | 不修改更新配置。 |

Windows 备份在 `C:\ProgramData\VpsSecurityBootstrap\backups\时间戳\`；需要恢复时，在管理员 PowerShell 中运行该目录的 `restore.ps1`。

## 固定版本完整校验

高价值 VPS 建议先校验安装器本身。当前版本为 `v1.3.5`。

### Debian

```bash
version=v1.3.5
base="https://github.com/elonjack/vps-security-bootstrap/releases/download/$version"
curl -fSLO "$base/install.sh"
curl -fSLO "$base/install.sh.sha256"
sha256sum --check install.sh.sha256
bash install.sh
```

### Windows

```powershell
$version = 'v1.3.5'
$base = "https://github.com/elonjack/vps-security-bootstrap/releases/download/$version"
Invoke-WebRequest "$base/install.ps1" -OutFile install.ps1
Invoke-WebRequest "$base/install.ps1.sha256" -OutFile install.ps1.sha256
$expected = ((Get-Content .\install.ps1.sha256 -Raw) -split '\s+')[0]
$actual = (Get-FileHash .\install.ps1 -Algorithm SHA256).Hash
if ($actual -ne $expected) { throw 'SHA-256 校验失败，禁止运行。' }
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

每个正式 Release 都附带 `install.sh`、`bootstrap.sh`、`install.ps1`、`windows-bootstrap.ps1` 及其 SHA-256 文件。

## 验证远程连接

Debian 完成后另开终端测试：

```bash
ssh -i ~/.ssh/id_ed25519 -p 你的端口 root@服务器IP
```

Windows 重启后用 `mstsc` 连接 `服务器IP:你的RDP端口`。成功连接前，请保留当前 RDP 会话或厂商控制台。
