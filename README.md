# VPS 安全初始化（Debian 12 / 13 + Windows 11）

同一个项目提供两套原生向导：Debian 使用 Bash，Windows 11 使用管理员 PowerShell。两套脚本都先显示配置摘要并备份，再修改系统；所有 `Y/n`、`y/N` 提示都明确标注直接回车时采用的默认动作。

| 系统 | 入口 | 主要防护 |
| --- | --- | --- |
| Debian 12 / 13 | `bootstrap.sh` | root SSH 公钥、Fail2ban、自动安全更新、可选 Telegram 通知 |
| Windows 11 Pro / Enterprise / Education | `windows-bootstrap.ps1` | RDP 换端口、NLA/TLS、防火墙/IP 白名单、RDP Guard、临时账户锁定、Telegram 通知 |

Windows 无法原生运行 Bash，Debian 也无法直接修改 Windows 注册表，因此采用两个入口比把两种系统强塞进一个脚本更可靠。交互界面的标题、菜单和输入提示统一使用黄色，成功为绿色，错误为红色；设置 `NO_COLOR=1` 可关闭颜色。

## Windows 11 VPS

### DD Windows 时先避开 3389

[`bin456789/reinstall`](https://github.com/bin456789/reinstall) 已支持 `--rdp-port PORT`。执行它原有的 Windows DD 命令时，可追加一个高位端口，例如：

```bash
--rdp-port 52089
```

这能让 Windows 第一次启动时就不监听默认 3389。端口不能与其他服务冲突，并且必须先在 VPS 厂商的安全组/云防火墙中放行。改端口主要减少批量扫描噪声，不代替密码、NLA、来源限制和封禁策略。

### 下载、校验并运行 Windows 向导

在 Windows 11 VPS 中打开“Windows PowerShell”，选择**以管理员身份运行**，然后从 `v1.2.0` Release 下载并执行：

```powershell
$version = 'v1.2.0'
$base = "https://github.com/elonjack/vps-security-bootstrap/releases/download/$version"
$work = Join-Path $env:TEMP "vps-security-$version"
New-Item -ItemType Directory -Path $work -Force | Out-Null
Invoke-WebRequest "$base/windows-bootstrap.ps1" -OutFile "$work\windows-bootstrap.ps1"
Invoke-WebRequest "$base/windows-bootstrap.ps1.sha256" -OutFile "$work\windows-bootstrap.ps1.sha256"
$expected = ((Get-Content "$work\windows-bootstrap.ps1.sha256" -Raw) -split '\s+')[0].ToLowerInvariant()
$actual = (Get-FileHash "$work\windows-bootstrap.ps1" -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $expected) { throw 'SHA-256 校验失败，禁止运行。' }
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$work\windows-bootstrap.ps1"
```

向导菜单提供“应用或更新安全防护”“查看当前状态”和“只更换 Telegram 配置”。每次重新运行“应用或更新”都可以再次选择 RDP 端口，不依赖 DD 脚本最初设置的端口。应用时会依次询问：

1. RDP 端口；当前为 3389 时默认生成一个未被监听的高位端口，否则默认保持当前端口。
2. 是否只允许固定 IP/CIDR 访问 RDP；只有固定公网出口时才填写，动态 IP 直接回车采用 `Any`。
3. 是否启用 RDP Guard；没有固定 IP 白名单时默认启用。
4. 是否设置“10 次失败、锁定 15 分钟、15 分钟后重置计数”的临时锁定策略。
5. 是否启用 Telegram 的 RDP 登录成功、来源封禁和解除封禁通知。
6. 显示完整摘要；最后确认默认为“否”，只有输入 `y` 才会开始修改。

脚本会要求 NLA、TLS 安全层和高加密，关闭远程协助，启用 Windows 防火墙的全部配置文件并保持默认阻止入站。它只新增/更新本项目管理的精确 RDP 端口规则，不会删除其他应用的防火墙规则。为保证重启前当前会话仍可用，改端口时会临时保留旧端口规则，并创建一次性开机任务在下次启动后自动删除该规则；RDP Guard 在重启前同时保护新旧端口。

### RDP Guard 如何防止账户被爆破锁定

默认策略是同一来源在 5 分钟内出现 5 次相关登录失败，就只在脚本保护的 RDP 新旧端口封禁该 IP 1 天；系统账户则在 10 次失败后临时锁定 15 分钟。RDP Guard 由安全日志事件 `4625` 立即触发，并每 5 分钟清理到期封禁。固定管理 IP/CIDR 会作为可信来源排除。

RDP Guard 是本机日志驱动的第二道防线，不是网络边界设备：极快的并发攻击仍可能先触发账户锁定，多个来源也可能分摊尝试次数。NLA 失败在 Windows 日志中可能表现为网络登录类型 3，因此 Guard 同时检查类型 3 和 10 的错误用户名/密码状态；其他网络服务的连续认证失败也可能让同一来源被禁止访问 RDP，但不会封禁该来源的其他端口。最可靠的方案仍是只在云防火墙和 Windows 防火墙中允许你的固定管理 IP；没有固定 IP 时，再组合高位端口、强且唯一的密码、NLA、RDP Guard 和临时锁定。

### Windows Telegram 通知

Windows 向导使用和 Debian 相同的 Bot Token、数字 Chat ID、VPS 名称配置方式。Token 采用隐藏输入，不会出现在命令行历史或计划任务参数中；配置保存在 `C:\ProgramData\VpsSecurityBootstrap\telegram.json`，目录和文件 ACL 只允许 `Administrators` 与 `SYSTEM` 访问。保存前必须成功发送测试消息，否则不会启用通知。

启用后会收到三类消息：

- Windows 安全日志 `4624`、Logon Type 10 对应的 RDP 登录成功通知，包括用户、来源 IP、端口和时间。
- RDP Guard 添加来源封禁时的通知，包括失败次数和封禁到期时间。
- 临时封禁到期、规则被移除时的解封通知。

Telegram API 临时不可用不会阻止 RDP Guard 执行封禁；错误只会写入受保护的本地日志，且不会写出 Token。菜单 `3. 更换 Telegram Bot Token 或通知目标` 只更新通知配置，不修改 RDP、端口、防火墙或账户策略。

### 重启、验证与回滚

RDP 端口修改在重启 Windows 后生效。脚本默认**不会重启**，完成时会再次提示：

1. 先在云厂商安全组放行新端口的 TCP/UDP。
2. 保持当前 RDP 或厂商控制台会话打开。
3. 重启后用 `服务器IP:新端口` 建立第二条连接。
4. 新连接成功后再关闭旧会话；Windows 本机旧端口规则会由一次性开机任务删除，云防火墙中的旧端口仍需手动关闭。

每次应用前都会把注册表、防火墙、本地安全策略和审核策略备份到 `C:\ProgramData\VpsSecurityBootstrap\backups\时间戳\`，并生成 `restore.ps1`。需要回滚时从厂商控制台或仍可用的管理员会话执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\ProgramData\VpsSecurityBootstrap\backups\时间戳\restore.ps1'
```

回滚会把 Windows 防火墙整体恢复到该时间戳的快照；备份以后新加的防火墙规则会被覆盖，因此应优先使用紧邻本次操作的备份。

自动化示例（固定管理 IP）：

```powershell
.\windows-bootstrap.ps1 `
  -Action Apply `
  -NonInteractive `
  -RdpPort 52089 `
  -AllowedRemoteAddress '203.0.113.10/32' `
  -TelegramTokenFile 'C:\Secure\tg-token' `
  -TelegramChatIdFile 'C:\Secure\tg-chat-id' `
  -TelegramVpsName 'HK-WIN-01'
```

Token 文件必须是普通文件，由当前管理员、`SYSTEM` 或 `Administrators` 所有，并且不能向这三者以外的主体授予读取权限。动态 IP 时省略 `-AllowedRemoteAddress`，默认启用 RDP Guard。只有明确接受相应风险时才使用 `-SkipRdpGuard` 或 `-SkipAccountPolicy`；使用 `-DisableTelegram` 可明确关闭 Windows 通知；只有确认云防火墙已经放行新端口时才添加 `-Reboot`。

Windows 防护不会修改 VPS 厂商的安全组，必须在厂商控制台单独配置。

### Windows 策略依据

- [Microsoft：更改远程桌面监听端口](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/remotepc/change-listening-port)
- [Microsoft：NLA 为远程桌面增加额外保护层](https://learn.microsoft.com/en-in/windows-server/remote/remote-desktop-services/remotepc/remote-desktop-allow-access)
- [Microsoft：账户锁定阈值的安全建议与拒绝服务取舍](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-10/security/threat-protection/security-policy-settings/account-lockout-threshold)
- [Microsoft：Windows 防火墙规则优先级](https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/rules)
- [Microsoft：失败登录事件 4625 与 RDP 的 Logon Type 10](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-10/security/threat-protection/auditing/event-4625)
- [Microsoft：登录成功事件 4624 与 RemoteInteractive 类型](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-10/security/threat-protection/auditing/event-4624)
- [Telegram：Bot API `sendMessage`](https://core.telegram.org/bots/api#sendmessage)

## Debian 12 / 13（root 专用）

Debian 向导只允许 `root` 使用 SSH 公钥登录，关闭 SSH 密码登录，启用 Fail2ban 和可选 Telegram 通知；完整系统升级仅在向导中明确确认，或自动化模式显式传入 `--system-upgrade` 时执行。脚本**不会创建新的 SSH 用户**。

适用范围：**Debian 12、Debian 13、systemd**。请在新 VPS，或你明确知道现有 SSH 配置可被替换的 VPS 上使用。

> 直接使用 root 的代价是：私钥一旦泄露，攻击者直接拥有最高权限。请为这台 VPS 使用专用、强口令保护的私钥，且不要共享。

## 一次复制运行（最新稳定版）

以 root 登录 VPS 后直接执行：

```bash
(
  set -Eeuo pipefail
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' EXIT
  base='https://github.com/elonjack/vps-security-bootstrap/releases/latest/download'
  curl -fsSLo "$workdir/bootstrap.sh" "$base/bootstrap.sh"
  curl -fsSLo "$workdir/bootstrap.sh.sha256" "$base/bootstrap.sh.sha256"
  cd "$workdir"
  sha256sum --check bootstrap.sh.sha256
  bash bootstrap.sh
)
```

这会完整下载最新正式 Release 及其 SHA-256 文件，校验通过后才运行，不会执行可变的 `main` 分支或下载到一半的脚本。脚本会等待你粘贴 SSH 公钥，不需要预先上传 `.pub` 文件，也不会要求创建管理员账号或 sudo 密码。运行前请确认你信任本仓库；该命令会以 root 权限执行远程脚本。

从 `v1.0.10` 起，新发布的 Release 会启用 GitHub 不可变保护：公开后其附件和 tag 不能被修改或删除。

## 固定版本运行（可选）

如果你希望始终运行某个确切版本，而不是以后自动更新到最新 Release，例如固定使用当前的 `v1.2.0`：

```bash
version=v1.2.0
curl -fsSLo bootstrap.sh \
  "https://github.com/elonjack/vps-security-bootstrap/releases/download/$version/bootstrap.sh"
bash bootstrap.sh
```

以后发布新版本后，如需固定使用新版，只需把命令中的版本号改为对应的新版本号。

## 下载后校验再运行（更稳妥）

“下载后立即执行”的一键命令依赖 GitHub 账号、Release 和 HTTPS 链路都可信。重要服务器建议先固定版本、校验 Release 提供的 SHA-256，再以 root 运行：

```bash
version=v1.2.0
base="https://github.com/elonjack/vps-security-bootstrap/releases/download/$version"
curl -fsSLO "$base/bootstrap.sh"
curl -fsSLO "$base/bootstrap.sh.sha256"
sha256sum --check bootstrap.sh.sha256
sudo bash bootstrap.sh
```

只有出现 `bootstrap.sh: OK` 时才继续执行。正式 Release 启用不可变保护，但新的恶意 Release 仍可能成为“latest”；因此高价值 VPS 更适合固定版本并核对校验值。


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
3. 可选填写 Fail2ban 白名单、是否执行系统更新和 Telegram 通知。每个确认项都会明确显示默认动作：`[y/N，回车=否]` 表示直接回车选择“否”，`[Y/n，回车=是]` 表示直接回车选择“是”；此时仅记录选择，尚未修改系统。
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
- `PermitRootLogin prohibit-password` 从 SSH 指令层直接禁止 root 密码登录；同时强制 `AuthenticationMethods publickey`，形成双重约束。
- `DisableForwarding yes` 禁用 SSH 的 TCP、Agent、X11 和隧道转发能力。

## Fail2ban 白名单与防火墙

向导中的 Fail2ban 白名单可直接回车留空；这表示不为任何公网地址添加白名单。白名单不是 SSH 登录白名单：即使不填写，持有正确私钥仍可正常登录。只有固定管理出口确实可能因多次失败登录而被误封时，才填写 IP 或 CIDR，例如 `203.0.113.10`、`203.0.113.0/24` 或 `2001:db8::/64`。多个条目使用英文逗号分隔，脚本会拒绝非法格式、空格和换行。

脚本安装并使用 `nftables`，但用途是让 Fail2ban 封禁爆破来源；它不会设置“默认拒绝入站”的全局主机防火墙策略。请在云厂商安全组/防火墙中仅放行实际需要的端口，例如 SSH 端口，以及部署 Web 服务时的 80/443。

## Debian Telegram 通知与 VPS 名称

启用 Telegram 前，先完成以下步骤：

1. 在 Telegram 搜索 `@BotFather`，发送 `/newbot` 并按提示创建机器人。
2. 保存 BotFather 返回的 HTTP API Token；它相当于机器人密码，不能分享。
3. 打开新建的机器人，点击 **Start** 并发送任意一条消息。
4. 在可信设备浏览器访问 `https://api.telegram.org/bot<你的Token>/getUpdates`，从返回内容的 `message.chat.id` 复制数字 Chat ID。
5. 在脚本中粘贴 Token、Chat ID，并填写 VPS 名称，例如 `HK-01`。粘贴 Token 后，终端不会显示任何字符、星号或长度；这是正常的安全保护，直接按回车即可。Chat ID 会正常显示。

通知会显示名称、主机、root 登录来源 IP、时间，以及 Fail2ban 封禁信息。

同一个 Bot Token 可以用于多台 VPS 的**通知**，为每台机器使用不同名称即可。接收通知的聊天应仅包含可信成员，因为消息含有来源 IP。

如果收到不认识的 root 登录成功通知，应视为私钥或服务器可能失陷：先通过云控制台或另一条可信连接保留访问，撤销可疑公钥、检查 SSH 日志、轮换密钥；无法确认影响范围时建议从可信镜像重建。

## 更换 Debian Telegram Bot Token

已经启用 Telegram 通知的 VPS，如需作废旧 Token 或更换机器人 Token，重新下载并运行本脚本后，在第一个菜单选择 `2. 更换 Telegram Bot Token`。该操作会隐藏输入的新 Token，默认保留原 Chat ID 和 VPS 名称；脚本会先用新配置发送测试通知，成功后才原子更新 `/etc/vps-security/telegram.env`。测试失败时旧配置保持不变。此操作**不会修改 SSH、公钥、端口、Fail2ban 或系统软件包**。

如果你已把脚本保存到 VPS，也可直接执行：

```bash
bash bootstrap.sh --rotate-telegram-token
```

测试通知失败时，脚本会取消更新并保留旧 Token；请核对 Token、Chat ID、网络，以及是否已在对应机器人聊天中点击 **Start**。

## 封禁策略

- SSH 在 3 分钟内失败 3 次：立即封禁来源 IP；首次封禁 1 天，之后逐级延长，最高 4 周。这是偏严格的策略，适合仅用 SSH 私钥、且能通过云控制台恢复的 VPS。
- 同一 IP 在 30 天内累计触发 5 次完整封禁：`recidive` jail 永久封禁该 IP 的所有端口。

## 自动化部署（可选）

```bash
bash bootstrap.sh \
  --public-key-file /root/root-login.pub \
  --ssh-port 22
```

参数模式默认只执行安装依赖所需的 `apt update`，不执行全系统 `apt upgrade`；如需立即安装全部可用更新，显式添加 `--system-upgrade`。

Telegram 自动化参数：

```bash
--telegram-token-file /root/tg-token \
--telegram-chat-id-file /root/tg-chat-id \
--telegram-vps-name 'HK-01'
```

Telegram 凭据文件必须归 root 所有、权限为 `0600` 或更严格；不要把 Token 放进命令行历史。脚本向 Telegram 发送通知时，会经由 root 进程的标准输入传递 API 地址，不会把 Token 放入 `curl` 命令行参数。

常用检查命令：

```bash
sshd -t
sshd -T | grep -E '^(port|permitrootlogin|allowusers|passwordauthentication|pubkeyauthentication) '
fail2ban-client status sshd
fail2ban-client status recidive
```

## 开发与检查规范

- Bash 使用 UTF-8、LF 和 2 空格缩进；Windows PowerShell 5.1 脚本使用带 BOM 的 UTF-8、LF 和 2 空格缩进，避免中文提示乱码。`.editorconfig` 与 `.gitattributes` 会约束格式。
- GitHub Actions 会检查 shebang、换行、Bash 语法、ShellCheck、PowerShell AST 解析、内嵌 RDP Guard/Telegram/恢复/旧端口清理脚本解析、PSScriptAnalyzer 警告、版本一致性和 Git 空白错误。
- 颜色仅在交互式终端启用；设置 `NO_COLOR=1` 或将输出重定向到文件时，不会输出 ANSI 颜色码。
- 黄色用于标题、菜单和输入提示，绿色用于成功状态，红色用于错误；无颜色环境仍保留完整文字语义。
