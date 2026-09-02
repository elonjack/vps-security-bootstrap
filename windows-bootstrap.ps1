#requires -Version 5.1

<#
.SYNOPSIS
  Windows 11 VPS RDP security bootstrap.

.DESCRIPTION
  Changes the RDP port, requires Network Level Authentication, enables Windows
  Firewall, optionally restricts RDP to trusted IP/CIDR ranges, configures a
  temporary account lockout policy, an event-driven RDP guard, and optional
  Telegram notifications for successful RDP logons, bans, and unbans.

  Run this script from an elevated Windows PowerShell 5.1 console. Registry,
  firewall, audit-policy, and local-security-policy backups are created before
  changes are made. RDP port changes take effect after Windows restarts.

.PARAMETER Action
  Menu, Apply, Status, or Telegram. Menu is the interactive default.

.PARAMETER AllowedRemoteAddress
  Optional IPv4/IPv6 addresses or CIDR ranges allowed to reach RDP.

.PARAMETER TelegramTokenFile
  A tightly ACL-restricted file whose first line contains the Bot Token.

.PARAMETER NonInteractive
  Disables prompts. Apply also requires an explicit RdpPort.

.EXAMPLE
  .\windows-bootstrap.ps1

.EXAMPLE
  .\windows-bootstrap.ps1 -Action Apply -NonInteractive -RdpPort 52089 -AllowedRemoteAddress '203.0.113.10/32'
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
  'PSAvoidUsingWriteHost',
  '',
  Justification = 'Write-Host is limited to the interactive color UI; redirected output remains plain.'
)]
[CmdletBinding()]
param(
  [ValidateSet('Menu', 'Apply', 'Status', 'Telegram', 'WindowsUpdate')]
  [string]$Action = 'Menu',

  [ValidateRange(1024, 65535)]
  [int]$RdpPort,

  [string[]]$AllowedRemoteAddress,

  [string]$TelegramTokenFile,
  [string]$TelegramChatIdFile,
  [string]$TelegramVpsName,

  [ValidateRange(3, 20)]
  [int]$BanThreshold = 5,

  [ValidateRange(1, 60)]
  [int]$BanWindowMinutes = 5,

  [ValidateRange(1, 10080)]
  [int]$BanMinutes = 1440,

  [switch]$SkipRdpGuard,
  [switch]$SkipAccountPolicy,
  [switch]$DisableTelegram,
  [switch]$NonInteractive,
  [switch]$Reboot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:ScriptVersion = 'v1.3.19'
$script:DataRoot = Join-Path $env:ProgramData 'VpsSecurityBootstrap'
$script:BackupRoot = Join-Path $script:DataRoot 'backups'
$script:GuardPath = Join-Path $script:DataRoot 'rdp-guard.ps1'
$script:GuardConfigPath = Join-Path $script:DataRoot 'rdp-guard.json'
$script:GuardStatePath = Join-Path $script:DataRoot 'rdp-guard-state.json'
$script:GuardTaskName = 'VpsSecurityBootstrap-RdpGuard'
$script:GuardCleanupTaskName = 'VpsSecurityBootstrap-RdpGuard-Cleanup'
$script:RdpPortCleanupPath = Join-Path $script:DataRoot 'rdp-port-cleanup.ps1'
$script:RdpPortCleanupTaskName = 'VpsSecurityBootstrap-RdpPort-Cleanup'
$script:TelegramConfigPath = Join-Path $script:DataRoot 'telegram.json'
$script:TelegramNotifierPath = Join-Path $script:DataRoot 'telegram-notify.ps1'
$script:TelegramLoginWatcherPath = Join-Path $script:DataRoot 'telegram-rdp-login.ps1'
$script:TelegramLoginStatePath = Join-Path $script:DataRoot 'telegram-rdp-login-state.json'
$script:TelegramLoginTaskName = 'VpsSecurityBootstrap-Telegram-RdpLogin'
$script:TelegramLoginCleanupTaskName = 'VpsSecurityBootstrap-Telegram-RdpLogin-Cleanup'
$script:FirewallGroup = 'VpsSecurityBootstrap'
$script:RdpRegistryPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
$script:TerminalServerPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
$script:TerminalServerPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
$script:RemoteAssistancePath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance'
$script:WindowsUpdatePolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$script:WindowsUpdateAuPolicyPath = Join-Path $script:WindowsUpdatePolicyPath 'AU'
$script:AuditLogonGuid = '{0CCE9215-69AE-11D9-BED3-505054503030}'
$script:UseColor = -not $env:NO_COLOR -and -not [Console]::IsOutputRedirected
$script:RdpPortWasProvided = $PSBoundParameters.ContainsKey('RdpPort')

try {
  [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch {
  Write-Verbose "无法修改控制台输出编码：$($_.Exception.Message)"
}

function Write-ColorLine {
  param(
    [Parameter(Mandatory)]
    [string]$Text,
    [ConsoleColor]$Color = [ConsoleColor]::Gray
  )

  if ($script:UseColor) {
    Write-Host $Text -ForegroundColor $Color
  } else {
    Write-Host $Text
  }
}

function Write-Title {
  param([Parameter(Mandatory)][string]$Text)
  Write-ColorLine -Text "`n==> $Text" -Color Yellow
}

function Write-Info {
  param([Parameter(Mandatory)][string]$Text)
  Write-ColorLine -Text $Text -Color Yellow
}

function Write-Success {
  param([Parameter(Mandatory)][string]$Text)
  Write-ColorLine -Text "完成：$Text" -Color Green
}

function Write-WarningLine {
  param([Parameter(Mandatory)][string]$Text)
  Write-ColorLine -Text "注意：$Text" -Color DarkYellow
}

function Write-TerminatingError {
  param([Parameter(Mandatory)][string]$Text)
  throw $Text
}

function Test-IsAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-SupportedWindows {
  if (-not (Test-IsAdministrator)) {
    Write-TerminatingError '请右键 Windows PowerShell，选择“以管理员身份运行”，再执行本脚本。'
  }

  $currentVersion = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  $build = [int]$currentVersion.CurrentBuildNumber
  if ($build -lt 22000) {
    Write-TerminatingError "仅支持 Windows 11（检测到构建号 $build）。Debian 请运行 bootstrap.sh。"
  }

  if ($currentVersion.EditionID -match '^(Core|CoreSingleLanguage|CoreCountrySpecific)$') {
    Write-TerminatingError 'Windows 11 家庭版不提供 RDP 主机功能；请使用 Pro、Enterprise 或 Education 版本。'
  }
}

function Read-Default {
  param(
    [Parameter(Mandatory)][string]$Prompt,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Default
  )

  $defaultLabel = if ([string]::IsNullOrEmpty($Default)) { '留空' } else { $Default }
  $promptText = "$Prompt [默认：$defaultLabel，回车采用默认]："
  if ($script:UseColor) {
    Write-Host $promptText -ForegroundColor Yellow -NoNewline
  } else {
    Write-Host $promptText -NoNewline
  }
  $value = Read-Host
  if ([string]::IsNullOrWhiteSpace($value)) {
    return $Default
  }
  return $value.Trim()
}

function Read-YesNo {
  param(
    [Parameter(Mandatory)][string]$Prompt,
    [ValidateSet('Y', 'N')][string]$Default = 'N'
  )

  while ($true) {
    if ($Default -eq 'Y') {
      $promptText = "$Prompt [Y/n，回车=是]："
      if ($script:UseColor) {
        Write-Host $promptText -ForegroundColor Yellow -NoNewline
      } else {
        Write-Host $promptText -NoNewline
      }
      $answer = Read-Host
      if ([string]::IsNullOrWhiteSpace($answer)) { return $true }
    } else {
      $promptText = "$Prompt [y/N，回车=否]："
      if ($script:UseColor) {
        Write-Host $promptText -ForegroundColor Yellow -NoNewline
      } else {
        Write-Host $promptText -NoNewline
      }
      $answer = Read-Host
      if ([string]::IsNullOrWhiteSpace($answer)) { return $false }
    }

    switch -Regex ($answer.Trim()) {
      '^(y|yes)$' { return $true }
      '^(n|no)$' { return $false }
      default { Write-ColorLine -Text '请输入 y 或 n；也可以直接回车采用默认值。' -Color Red }
    }
  }
}

function Read-Secret {
  param([Parameter(Mandatory)][string]$Prompt)

  $promptText = "$Prompt（输入不回显，粘贴后按回车）："
  if ($script:UseColor) {
    Write-Host $promptText -ForegroundColor Yellow -NoNewline
  } else {
    Write-Host $promptText -NoNewline
  }
  $secureValue = Read-Host -AsSecureString
  $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureValue)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
  }
}

function Get-PrivateFileValue {
  param([Parameter(Mandatory)][string]$Path)

  $item = Get-Item -LiteralPath $Path -Force
  if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    Write-TerminatingError "Telegram Token 文件必须是普通文件，不能是目录或链接：$Path"
  }

  $acl = Get-Acl -LiteralPath $item.FullName
  $allowedOwners = @(
    [Security.Principal.WindowsIdentity]::GetCurrent().User.Value,
    'S-1-5-18',
    'S-1-5-32-544'
  )
  $ownerSid = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
  if ($ownerSid -notin $allowedOwners) {
    Write-TerminatingError 'Telegram Token 文件必须由当前管理员、SYSTEM 或 Administrators 所有。'
  }

  $readRights = [Security.AccessControl.FileSystemRights]::Read -bor
    [Security.AccessControl.FileSystemRights]::ReadData -bor
    [Security.AccessControl.FileSystemRights]::ReadAndExecute
  $rules = $acl.GetAccessRules(
    $true,
    $true,
    [Security.Principal.SecurityIdentifier]
  )
  foreach ($rule in $rules) {
    if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
      $rule.IdentityReference.Value -notin $allowedOwners -and
      ($rule.FileSystemRights -band $readRights)) {
      Write-TerminatingError 'Telegram Token 文件存在当前管理员、Administrators、SYSTEM 之外的可读权限。'
    }
  }

  return ([string](Get-Content -LiteralPath $item.FullName -TotalCount 1 -Encoding UTF8)).Trim()
}

function Get-FirstFileValue {
  param([Parameter(Mandatory)][string]$Path)

  $item = Get-Item -LiteralPath $Path -Force
  if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    Write-TerminatingError "必须提供普通文件，不能是目录或链接：$Path"
  }
  return ([string](Get-Content -LiteralPath $item.FullName -TotalCount 1 -Encoding UTF8)).Trim()
}

function Assert-TelegramSetting {
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$Token,
    [Parameter(Mandatory)][AllowEmptyString()][string]$ChatId,
    [Parameter(Mandatory)][AllowEmptyString()][string]$VpsName
  )

  if ($Token -notmatch '^[0-9]{6,12}:[A-Za-z0-9_-]{20,}$') {
    Write-TerminatingError 'Telegram Bot Token 格式无效；请粘贴 BotFather 返回的完整 Token。'
  }
  if ($ChatId -notmatch '^-?[0-9]+$') {
    Write-TerminatingError 'Telegram Chat ID 必须是数字；群组 Chat ID 可以是负数。'
  }
  if ([string]::IsNullOrWhiteSpace($VpsName) -or $VpsName.Length -gt 80 -or $VpsName -match "[`r`n]") {
    Write-TerminatingError 'Telegram VPS 名称不能为空、不能包含换行，且最多 80 个字符。'
  }
}

function Get-TelegramApiFailureMessage {
  param([Parameter(Mandatory)][object]$ErrorRecord)

  $statusCode = $null
  $description = ''
  $response = $null
  if ($ErrorRecord.Exception.PSObject.Properties.Name -contains 'Response') {
    $response = $ErrorRecord.Exception.Response
  }
  if ($response) {
    try { $statusCode = [int]$response.StatusCode } catch { $statusCode = $null }
  }

  $payloads = [Collections.Generic.List[string]]::new()
  if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
    $payloads.Add([string]$ErrorRecord.ErrorDetails.Message)
  }
  if ($response) {
    try {
      $stream = $response.GetResponseStream()
      if ($stream) {
        $reader = [IO.StreamReader]::new($stream)
        try {
          $payloads.Add($reader.ReadToEnd())
        } finally {
          $reader.Dispose()
        }
      }
    } catch {
      Write-Verbose '无法读取 Telegram API 错误响应正文。'
    }
  }

  foreach ($payload in $payloads) {
    if ([string]::IsNullOrWhiteSpace($payload)) { continue }
    try {
      $errorResponse = $payload | ConvertFrom-Json -ErrorAction Stop
      if ($errorResponse.description) {
        $description = [string]$errorResponse.description
        if (-not $statusCode -and $errorResponse.error_code) {
          $statusCode = [int]$errorResponse.error_code
        }
        break
      }
    } catch {
      Write-Verbose 'Telegram API 错误响应不是可识别的 JSON。'
    }
  }

  if ($statusCode -eq 401 -or $description -match '(?i)unauthorized') {
    return 'Bot Token 被 Telegram 拒绝（401 Unauthorized）；请从 BotFather 重新复制完整 Token。'
  }
  if ($description -match '(?i)chat not found') {
    return 'Telegram 找不到这个 Chat ID；请先在 Telegram 中打开机器人并发送 /start，再核对 Chat ID。'
  }
  if ($statusCode -eq 403 -or $description -match '(?i)bot was blocked|forbidden') {
    return '机器人无权向该会话发消息（403 Forbidden）；请解除屏蔽并向机器人发送 /start。'
  }
  if ($statusCode -eq 429) {
    return 'Telegram API 请求过于频繁（429）；请稍后重试。'
  }
  if ($description) {
    return "Telegram API 返回错误$(if ($statusCode) { " $statusCode" })：$description"
  }

  if ($ErrorRecord.Exception -is [Net.WebException]) {
    switch ($ErrorRecord.Exception.Status) {
      'NameResolutionFailure' { return '无法解析 api.telegram.org（DNS 失败）；请检查 VPS 的 DNS 和网络。' }
      'ConnectFailure' { return '无法连接 api.telegram.org；请检查 VPS 出站网络、防火墙或地区网络限制。' }
      'Timeout' { return '连接 Telegram API 超时；请检查 VPS 出站网络。' }
      'TrustFailure' { return 'Telegram API TLS 证书验证失败；请检查系统时间和根证书。' }
    }
  }
  return '无法连接 Telegram API；请检查 VPS 出站网络、DNS 和 TLS。'
}

function Invoke-TelegramApiRequest {
  param(
    [Parameter(Mandatory)][string]$Token,
    [Parameter(Mandatory)][ValidateSet('getMe', 'sendMessage')][string]$ApiMethod,
    [hashtable]$Body
  )

  $requestParameters = @{
    Uri = "https://api.telegram.org/bot$Token/$ApiMethod"
    Method = 'Post'
    ContentType = 'application/x-www-form-urlencoded'
    TimeoutSec = 10
    ErrorAction = 'Stop'
  }
  if ($Body) { $requestParameters.Body = $Body }

  try {
    $response = Invoke-RestMethod @requestParameters
  } catch {
    Write-TerminatingError (Get-TelegramApiFailureMessage -ErrorRecord $_)
  }
  if ($null -eq $response -or -not $response.ok) {
    Write-TerminatingError "Telegram API 的 $ApiMethod 请求未返回成功状态。"
  }
  return $response
}

function Test-TelegramConfiguration {
  param([Parameter(Mandatory)][object]$Configuration)

  Assert-TelegramSetting `
    -Token ([string]$Configuration.token) `
    -ChatId ([string]$Configuration.chatId) `
    -VpsName ([string]$Configuration.vpsName)
  Invoke-TelegramApiRequest `
    -Token ([string]$Configuration.token) `
    -ApiMethod getMe | Out-Null
  Invoke-TelegramApiRequest `
    -Token ([string]$Configuration.token) `
    -ApiMethod sendMessage `
    -Body @{
      chat_id = [string]$Configuration.chatId
      text = "Windows 安全防护 Telegram 预检成功。`nVPS：$([string]$Configuration.vpsName)"
      disable_web_page_preview = 'true'
      protect_content = 'true'
    } | Out-Null
}

function Get-ExistingTelegramConfiguration {
  if (-not (Test-Path -LiteralPath $script:TelegramConfigPath)) { return $null }
  try {
    $configuration = Get-Content -LiteralPath $script:TelegramConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-TelegramSetting `
      -Token ([string]$configuration.token) `
      -ChatId ([string]$configuration.chatId) `
      -VpsName ([string]$configuration.vpsName)
    return $configuration
  } catch {
    Write-TerminatingError "现有 Telegram 配置损坏：$($_.Exception.Message)"
  }
}

function Get-DesiredTelegramConfiguration {
  param([switch]$RotateOnly)

  $existing = Get-ExistingTelegramConfiguration
  if ($NonInteractive) {
    if ($DisableTelegram) {
      if ($TelegramTokenFile -or $TelegramChatIdFile) {
        Write-TerminatingError '-DisableTelegram 不能与 Telegram 凭据文件同时使用。'
      }
      return [pscustomobject]@{ Enabled = $false; Configuration = $null }
    }
    if ($TelegramTokenFile -or $TelegramChatIdFile) {
      if (-not $TelegramTokenFile -or -not $TelegramChatIdFile) {
        Write-TerminatingError '非交互配置 Telegram 时必须同时提供 -TelegramTokenFile 和 -TelegramChatIdFile。'
      }
      $token = Get-PrivateFileValue -Path $TelegramTokenFile
      $chatId = Get-FirstFileValue -Path $TelegramChatIdFile
      $vpsName = if ($TelegramVpsName) { $TelegramVpsName } else { $env:COMPUTERNAME }
      Assert-TelegramSetting -Token $token -ChatId $chatId -VpsName $vpsName
      return [pscustomobject]@{
        Enabled = $true
        Configuration = [pscustomobject]@{ token = $token; chatId = $chatId; vpsName = $vpsName }
      }
    }
    if ($existing) {
      return [pscustomobject]@{ Enabled = $true; Configuration = $existing }
    }
    if ($RotateOnly) {
      Write-TerminatingError '非交互 Telegram 配置必须提供 Token 和 Chat ID 文件。'
    }
    return [pscustomobject]@{ Enabled = $false; Configuration = $null }
  }

  if (-not $RotateOnly) {
    $default = if ($existing) { 'Y' } else { 'N' }
    if (-not (Read-YesNo -Prompt '启用 Telegram 的 RDP 登录、封禁和解封通知吗？' -Default $default)) {
      return [pscustomobject]@{ Enabled = $false; Configuration = $null }
    }
    if ($existing -and (Read-YesNo -Prompt '保留并继续使用现有 Telegram 配置吗？' -Default Y)) {
      return [pscustomobject]@{ Enabled = $true; Configuration = $existing }
    }
  }

  $defaultChatId = if ($existing) { [string]$existing.chatId } else { '' }
  $defaultVpsName = if ($existing) { [string]$existing.vpsName } else { $env:COMPUTERNAME }
  while ($true) {
    Write-Info 'Telegram Token 不会显示，也不会写入命令行历史；保存文件仅允许 Administrators 和 SYSTEM 读取。'
    $token = Read-Secret -Prompt 'Telegram Bot Token'
    $chatId = Read-Default -Prompt 'Telegram Chat ID' -Default $defaultChatId
    $vpsName = Read-Default -Prompt 'Telegram 中显示的 VPS 名称' -Default $defaultVpsName
    try {
      Assert-TelegramSetting -Token $token -ChatId $chatId -VpsName $vpsName
      break
    } catch {
      Write-ColorLine -Text "Telegram 配置无效：$($_.Exception.Message) 请重新输入。" -Color Red
    }
  }

  return [pscustomobject]@{
    Enabled = $true
    Configuration = [pscustomobject]@{ token = $token; chatId = $chatId; vpsName = $vpsName }
  }
}

function Confirm-TelegramConfiguration {
  param(
    [Parameter(Mandatory)][object]$Telegram,
    [switch]$RotateOnly
  )

  while ($Telegram.Enabled) {
    try {
      Test-TelegramConfiguration -Configuration $Telegram.Configuration
      Write-Success 'Telegram Bot Token 和 Chat ID 预检通过，测试消息已发送'
      return $Telegram
    } catch {
      Write-ColorLine -Text "Telegram 预检失败：$($_.Exception.Message)" -Color Red
      if ($NonInteractive) {
        Write-TerminatingError "Telegram 预检失败：$($_.Exception.Message)"
      }
      if (Read-YesNo -Prompt '重新输入 Telegram Token 和 Chat ID 吗？' -Default Y) {
        $Telegram = Get-DesiredTelegramConfiguration -RotateOnly
        continue
      }
      if ($RotateOnly) {
        Write-TerminatingError 'Telegram 配置未更新；RDP、端口、防火墙和账户策略均未修改。'
      }
      Write-WarningLine '已跳过 Telegram，继续应用其余 Windows RDP 安全防护。'
      return [pscustomobject]@{ Enabled = $false; Configuration = $null }
    }
  }
  return $Telegram
}

function Get-CurrentRdpPort {
  try {
    $value = Get-ItemPropertyValue -Path $script:RdpRegistryPath -Name PortNumber -ErrorAction Stop
    return [int]$value
  } catch {
    Write-TerminatingError "无法读取当前 RDP 端口。请确认远程桌面服务已安装且注册表路径可访问。原始错误：$($_.Exception.Message)"
  }
}

function Get-ListeningLocalPort {
  try {
    $ipProperties = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
    return @(
      @($ipProperties.GetActiveTcpListeners() | Select-Object -ExpandProperty Port) +
      @($ipProperties.GetActiveUdpListeners() | Select-Object -ExpandProperty Port) |
        Select-Object -Unique
    )
  } catch {
    Write-TerminatingError "无法枚举本机监听端口；为避免选择冲突端口，已停止配置。原始错误：$($_.Exception.Message)"
  }
}

function Get-RandomAvailablePort {
  $usedPorts = @(Get-ListeningLocalPort)

  $random = [Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $bytes = New-Object byte[] 4
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
      $random.GetBytes($bytes)
      $candidate = 20000 + ([BitConverter]::ToUInt32($bytes, 0) % 40000)
      if ($usedPorts -notcontains $candidate) {
        return [int]$candidate
      }
    }
  } finally {
    $random.Dispose()
  }

  Write-TerminatingError '无法自动找到空闲的高位端口，请使用 -RdpPort 手动指定。'
}

function Test-PortAvailable {
  param(
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][int]$CurrentPort
  )

  if ($Port -eq $CurrentPort) { return $true }
  return $Port -notin @(Get-ListeningLocalPort)
}

function Test-IpOrCidr {
  param([Parameter(Mandatory)][string]$Value)

  $parts = $Value.Split('/')
  if ($parts.Count -gt 2 -or [string]::IsNullOrWhiteSpace($parts[0]) -or $parts[0].Contains('%')) {
    return $false
  }

  $address = $null
  if (-not [Net.IPAddress]::TryParse($parts[0], [ref]$address)) {
    return $false
  }
  if ($address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
    $octets = $parts[0].Split('.')
    if ($octets.Count -ne 4) { return $false }
    foreach ($octet in $octets) {
      if ($octet -notmatch '^(0|[1-9][0-9]{0,2})$' -or [int]$octet -gt 255) {
        return $false
      }
    }
  } elseif (-not $parts[0].Contains(':')) {
    return $false
  }
  if ($parts.Count -eq 1) { return $true }

  $prefix = 0
  if (-not [int]::TryParse($parts[1], [ref]$prefix)) {
    return $false
  }
  $maxPrefix = if ($address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) { 32 } else { 128 }
  return $prefix -ge 0 -and $prefix -le $maxPrefix
}

function Test-AddressInNetwork {
  param(
    [Parameter(Mandatory)][string]$Address,
    [Parameter(Mandatory)][string]$Network
  )

  $ip = $null
  $parts = $Network.Split('/')
  $base = $null
  if (-not [Net.IPAddress]::TryParse($Address, [ref]$ip)) { return $false }
  if (-not [Net.IPAddress]::TryParse($parts[0], [ref]$base)) { return $false }
  if ($ip.AddressFamily -ne $base.AddressFamily) { return $false }
  if ($parts.Count -eq 1) { return $ip.Equals($base) }

  $prefix = [int]$parts[1]
  $ipBytes = $ip.GetAddressBytes()
  $baseBytes = $base.GetAddressBytes()
  $fullBytes = [Math]::Floor($prefix / 8)
  $remainingBits = $prefix % 8
  for ($index = 0; $index -lt $fullBytes; $index++) {
    if ($ipBytes[$index] -ne $baseBytes[$index]) { return $false }
  }
  if ($remainingBits -gt 0) {
    $mask = (0xff -shl (8 - $remainingBits)) -band 0xff
    if (($ipBytes[$fullBytes] -band $mask) -ne ($baseBytes[$fullBytes] -band $mask)) {
      return $false
    }
  }
  return $true
}

function ConvertTo-RemoteAddressList {
  param([string[]]$InputValue)

  $result = [Collections.Generic.List[string]]::new()
  foreach ($item in @($InputValue)) {
    if ([string]::IsNullOrWhiteSpace($item)) { continue }
    foreach ($part in $item.Split(',')) {
      $candidate = $part.Trim()
      if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
      if (-not (Test-IpOrCidr -Value $candidate)) {
        Write-TerminatingError "无效的 IP/CIDR：$candidate"
      }
      if ($result -notcontains $candidate) {
        $result.Add($candidate)
      }
    }
  }
  return $result.ToArray()
}

function Get-CurrentRdpClientAddress {
  param([Parameter(Mandatory)][int]$Port)

  try {
    return @(
      Get-NetTCPConnection -State Established -LocalPort $Port -ErrorAction Stop |
        Where-Object { $_.RemoteAddress -notin @('127.0.0.1', '::1') } |
        Select-Object -ExpandProperty RemoteAddress -Unique
    )
  } catch {
    Write-Verbose "无法检测当前 RDP 客户端地址，将跳过此提示：$($_.Exception.Message)"
    return @()
  }
}

function Invoke-NativeCommand {
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [Parameter(Mandatory)][string[]]$ArgumentList,
    [switch]$IgnoreExitCode
  )

  $output = @(& $FilePath @ArgumentList 2>&1)
  $exitCode = $LASTEXITCODE
  if (-not $IgnoreExitCode -and $exitCode -ne 0) {
    $details = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    Write-TerminatingError "$FilePath 执行失败，退出码：$exitCode`n$details"
  }
  return $exitCode
}

function Export-RegistryKeyBackup {
  param(
    [Parameter(Mandatory)][string]$RegistryPath,
    [Parameter(Mandatory)][string]$RegistryKey,
    [Parameter(Mandatory)][string]$ExportPath,
    [Parameter(Mandatory)][string]$MissingMarkerPath,
    [Parameter(Mandatory)][string]$Description
  )

  if (-not (Test-Path -LiteralPath $RegistryPath)) {
    New-Item -ItemType File -Path $MissingMarkerPath -Force | Out-Null
    Write-Verbose "备份时未找到 $Description，已记录为不存在。"
    return
  }

  Invoke-NativeCommand -FilePath 'reg.exe' -ArgumentList @(
    'export', $RegistryKey, $ExportPath, '/y'
  ) | Out-Null
  if (-not (Test-Path -LiteralPath $ExportPath)) {
    Write-TerminatingError "$Description 存在，但注册表导出没有生成备份文件：$ExportPath"
  }
}

function Protect-DataDirectory {
  New-Item -ItemType Directory -Path $script:DataRoot -Force | Out-Null
  New-Item -ItemType Directory -Path $script:BackupRoot -Force | Out-Null

  $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
  $administratorsSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
  $items = @((Get-Item -LiteralPath $script:DataRoot -Force)) + @(
    Get-ChildItem -LiteralPath $script:DataRoot -Force -Recurse -ErrorAction SilentlyContinue |
      Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) }
  )
  foreach ($item in $items) {
    if ($item.PSIsContainer) {
      $acl = [Security.AccessControl.DirectorySecurity]::new()
      $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    } else {
      $acl = [Security.AccessControl.FileSecurity]::new()
      $inheritance = [Security.AccessControl.InheritanceFlags]::None
    }
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($administratorsSid)
    foreach ($sid in @($systemSid, $administratorsSid)) {
      $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $sid,
        [Security.AccessControl.FileSystemRights]::FullControl,
        $inheritance,
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow
      )
      $acl.AddAccessRule($rule) | Out-Null
    }
    Set-Acl -LiteralPath $item.FullName -AclObject $acl
  }
}

function Save-SecurityBackup {
  [CmdletBinding(SupportsShouldProcess)]
  param()

  if (-not $PSCmdlet.ShouldProcess($script:BackupRoot, '备份 Windows 安全配置')) { return }
  Write-Title '备份当前 Windows 安全配置'
  Protect-DataDirectory

  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $backupPath = Join-Path $script:BackupRoot $stamp
  New-Item -ItemType Directory -Path $backupPath -Force | Out-Null

  Export-RegistryKeyBackup `
    -RegistryPath $script:TerminalServerPath `
    -RegistryKey 'HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server' `
    -ExportPath (Join-Path $backupPath 'terminal-server.reg') `
    -MissingMarkerPath (Join-Path $backupPath 'terminal-server.missing') `
    -Description '终端服务注册表项'
  Export-RegistryKeyBackup `
    -RegistryPath $script:RemoteAssistancePath `
    -RegistryKey 'HKLM\SYSTEM\CurrentControlSet\Control\Remote Assistance' `
    -ExportPath (Join-Path $backupPath 'remote-assistance.reg') `
    -MissingMarkerPath (Join-Path $backupPath 'remote-assistance.missing') `
    -Description '远程协助注册表项'
  Export-RegistryKeyBackup `
    -RegistryPath $script:TerminalServerPolicyPath `
    -RegistryKey 'HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' `
    -ExportPath (Join-Path $backupPath 'terminal-server-policy.reg') `
    -MissingMarkerPath (Join-Path $backupPath 'terminal-server-policy.missing') `
    -Description '终端服务策略注册表项'
  Export-RegistryKeyBackup `
    -RegistryPath $script:WindowsUpdatePolicyPath `
    -RegistryKey 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' `
    -ExportPath (Join-Path $backupPath 'windows-update-policy.reg') `
    -MissingMarkerPath (Join-Path $backupPath 'windows-update-policy.missing') `
    -Description 'Windows Update 策略注册表项'
  Invoke-NativeCommand -FilePath 'netsh.exe' -ArgumentList @(
    'advfirewall', 'export', (Join-Path $backupPath 'firewall.wfw')
  ) | Out-Null
  Invoke-NativeCommand -FilePath 'secedit.exe' -ArgumentList @(
    '/export', '/cfg', (Join-Path $backupPath 'security-policy.inf'), '/quiet'
  ) | Out-Null
  Invoke-NativeCommand -FilePath 'auditpol.exe' -ArgumentList @(
    '/backup', "/file:$(Join-Path $backupPath 'audit-policy.csv')"
  ) | Out-Null

  $guardFiles = @(
    @{ Source = $script:GuardPath; Backup = 'rdp-guard.ps1.before' },
    @{ Source = $script:GuardConfigPath; Backup = 'rdp-guard.json.before' },
    @{ Source = $script:GuardStatePath; Backup = 'rdp-guard-state.json.before' },
    @{ Source = $script:RdpPortCleanupPath; Backup = 'rdp-port-cleanup.ps1.before' },
    @{ Source = (Join-Path $script:DataRoot 'rdp-guard.log'); Backup = 'rdp-guard.log.before' },
    @{ Source = (Join-Path $script:DataRoot 'rdp-guard.log.1'); Backup = 'rdp-guard.log.1.before' },
    @{ Source = $script:TelegramConfigPath; Backup = 'telegram.json.before' },
    @{ Source = $script:TelegramNotifierPath; Backup = 'telegram-notify.ps1.before' },
    @{ Source = $script:TelegramLoginWatcherPath; Backup = 'telegram-rdp-login.ps1.before' },
    @{ Source = $script:TelegramLoginStatePath; Backup = 'telegram-rdp-login-state.json.before' },
    @{ Source = (Join-Path $script:DataRoot 'telegram-error.log'); Backup = 'telegram-error.log.before' },
    @{ Source = (Join-Path $script:DataRoot 'telegram-error.log.1'); Backup = 'telegram-error.log.1.before' }
  )
  foreach ($guardFile in $guardFiles) {
    if (Test-Path -LiteralPath $guardFile.Source) {
      Copy-Item -LiteralPath $guardFile.Source -Destination (Join-Path $backupPath $guardFile.Backup) -Force
    }
  }
  foreach ($taskName in @(
    $script:GuardTaskName,
    $script:GuardCleanupTaskName,
    $script:RdpPortCleanupTaskName,
    $script:TelegramLoginTaskName,
    $script:TelegramLoginCleanupTaskName
  )) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
      Export-ScheduledTask -TaskName $taskName |
        Set-Content -LiteralPath (Join-Path $backupPath "$taskName.xml") -Encoding UTF8
    }
  }

  $policySettings = Get-ItemProperty -Path $script:TerminalServerPolicyPath -ErrorAction SilentlyContinue
  $policyValueExists = $false
  $policyValue = $null
  if ($policySettings -and $policySettings.PSObject.Properties.Name -contains 'UserAuthentication') {
    $policyValueExists = $true
    $policyValue = [int]$policySettings.UserAuthentication
  }
  $windowsUpdateService = Get-CimInstance -ClassName Win32_Service -Filter "Name='wuauserv'" -ErrorAction Stop

  $metadata = [ordered]@{
    createdAt = (Get-Date).ToString('o')
    computerName = $env:COMPUTERNAME
    scriptVersion = $script:ScriptVersion
    rdpPort = Get-CurrentRdpPort
    policyUserAuthenticationExists = $policyValueExists
    policyUserAuthenticationValue = $policyValue
    windowsUpdateServiceStartMode = $windowsUpdateService.StartMode
  }
  $metadata | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupPath 'metadata.json') -Encoding UTF8
  Write-RestoreScript -BackupPath $backupPath
  Write-Success "备份已保存：$backupPath"
  return $backupPath
}

function Get-RestoreSource {
  return @'
#requires -Version 5.1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
  'PSAvoidUsingWriteHost',
  '',
  Justification = 'The standalone recovery script uses color for its two interactive completion messages.'
)]
[CmdletBinding()]
param([switch]$Reboot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-RestoreNative {
  param([string]$FilePath, [string[]]$ArgumentList)
  $output = @(& $FilePath @ArgumentList 2>&1)
  if ($LASTEXITCODE -ne 0) {
    $details = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    throw "$FilePath 恢复失败，退出码：$LASTEXITCODE`n$details"
  }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw '请以管理员身份运行此恢复脚本。'
}

$backupPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$dataRoot = Split-Path -Parent (Split-Path -Parent $backupPath)
$metadata = Get-Content -LiteralPath (Join-Path $backupPath 'metadata.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Unregister-ScheduledTask -TaskName 'VpsSecurityBootstrap-RdpGuard' -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'VpsSecurityBootstrap-RdpGuard-Cleanup' -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'VpsSecurityBootstrap-RdpPort-Cleanup' -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'VpsSecurityBootstrap-Telegram-RdpLogin' -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'VpsSecurityBootstrap-Telegram-RdpLogin-Cleanup' -Confirm:$false -ErrorAction SilentlyContinue
Get-NetFirewallRule -Group 'VpsSecurityBootstrap' -ErrorAction SilentlyContinue |
  Remove-NetFirewallRule -ErrorAction SilentlyContinue

$terminalServerRegistry = Join-Path $backupPath 'terminal-server.reg'
if (Test-Path -LiteralPath $terminalServerRegistry) {
  Invoke-RestoreNative 'reg.exe' @('import', $terminalServerRegistry)
}
$remoteAssistanceRegistry = Join-Path $backupPath 'remote-assistance.reg'
$remoteAssistanceMissing = Join-Path $backupPath 'remote-assistance.missing'
if (Test-Path -LiteralPath $remoteAssistanceRegistry) {
  Invoke-RestoreNative 'reg.exe' @('import', $remoteAssistanceRegistry)
} elseif (Test-Path -LiteralPath $remoteAssistanceMissing) {
  Remove-Item -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' -Recurse -Force -ErrorAction SilentlyContinue
}
$policyRegistry = Join-Path $backupPath 'terminal-server-policy.reg'
$policyMissing = Join-Path $backupPath 'terminal-server-policy.missing'
if (Test-Path -LiteralPath $policyRegistry) {
  Invoke-RestoreNative 'reg.exe' @('import', $policyRegistry)
}
if ([bool]$metadata.policyUserAuthenticationExists) {
  New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Force | Out-Null
  New-ItemProperty `
    -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' `
    -Name UserAuthentication `
    -PropertyType DWord `
    -Value ([int]$metadata.policyUserAuthenticationValue) `
    -Force | Out-Null
} elseif ((Test-Path -LiteralPath $policyMissing) -or (Test-Path -LiteralPath $policyRegistry)) {
  Remove-ItemProperty `
    -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' `
    -Name UserAuthentication `
    -ErrorAction SilentlyContinue
}
$windowsUpdatePolicyRegistry = Join-Path $backupPath 'windows-update-policy.reg'
$windowsUpdatePolicyMissing = Join-Path $backupPath 'windows-update-policy.missing'
if (Test-Path -LiteralPath $windowsUpdatePolicyRegistry) {
  Invoke-RestoreNative 'reg.exe' @('import', $windowsUpdatePolicyRegistry)
} elseif (Test-Path -LiteralPath $windowsUpdatePolicyMissing) {
  Remove-Item -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Recurse -Force -ErrorAction SilentlyContinue
}
if ($metadata.PSObject.Properties.Name -contains 'windowsUpdateServiceStartMode') {
  $windowsUpdateStartType = switch ([string]$metadata.windowsUpdateServiceStartMode) {
    'Auto' { 'auto' }
    'Manual' { 'demand' }
    'Disabled' { 'disabled' }
    default { $null }
  }
  if ($windowsUpdateStartType) {
    Invoke-RestoreNative 'sc.exe' @('config', 'wuauserv', 'start=', $windowsUpdateStartType)
  }
}
Invoke-RestoreNative 'netsh.exe' @('advfirewall', 'import', (Join-Path $backupPath 'firewall.wfw'))
Invoke-RestoreNative 'secedit.exe' @(
  '/configure', '/db', (Join-Path $backupPath 'restore.sdb'),
  '/cfg', (Join-Path $backupPath 'security-policy.inf'), '/quiet'
)
Invoke-RestoreNative 'auditpol.exe' @('/restore', "/file:$(Join-Path $backupPath 'audit-policy.csv')")

$guardFiles = @(
  @{ Target = (Join-Path $dataRoot 'rdp-guard.ps1'); Backup = 'rdp-guard.ps1.before' },
  @{ Target = (Join-Path $dataRoot 'rdp-guard.json'); Backup = 'rdp-guard.json.before' },
  @{ Target = (Join-Path $dataRoot 'rdp-guard-state.json'); Backup = 'rdp-guard-state.json.before' },
  @{ Target = (Join-Path $dataRoot 'rdp-port-cleanup.ps1'); Backup = 'rdp-port-cleanup.ps1.before' },
  @{ Target = (Join-Path $dataRoot 'rdp-guard.log'); Backup = 'rdp-guard.log.before' },
  @{ Target = (Join-Path $dataRoot 'rdp-guard.log.1'); Backup = 'rdp-guard.log.1.before' },
  @{ Target = (Join-Path $dataRoot 'telegram.json'); Backup = 'telegram.json.before' },
  @{ Target = (Join-Path $dataRoot 'telegram-notify.ps1'); Backup = 'telegram-notify.ps1.before' },
  @{ Target = (Join-Path $dataRoot 'telegram-rdp-login.ps1'); Backup = 'telegram-rdp-login.ps1.before' },
  @{ Target = (Join-Path $dataRoot 'telegram-rdp-login-state.json'); Backup = 'telegram-rdp-login-state.json.before' },
  @{ Target = (Join-Path $dataRoot 'telegram-error.log'); Backup = 'telegram-error.log.before' },
  @{ Target = (Join-Path $dataRoot 'telegram-error.log.1'); Backup = 'telegram-error.log.1.before' }
)
foreach ($guardFile in $guardFiles) {
  $source = Join-Path $backupPath $guardFile.Backup
  if (Test-Path -LiteralPath $source) {
    Copy-Item -LiteralPath $source -Destination $guardFile.Target -Force
  } else {
    Remove-Item -LiteralPath $guardFile.Target -Force -ErrorAction SilentlyContinue
  }
}

foreach ($taskName in @(
  'VpsSecurityBootstrap-RdpGuard',
  'VpsSecurityBootstrap-RdpGuard-Cleanup',
  'VpsSecurityBootstrap-RdpPort-Cleanup',
  'VpsSecurityBootstrap-Telegram-RdpLogin',
  'VpsSecurityBootstrap-Telegram-RdpLogin-Cleanup'
)) {
  $taskXml = Join-Path $backupPath "$taskName.xml"
  if (Test-Path -LiteralPath $taskXml) {
    Register-ScheduledTask `
      -TaskName $taskName `
      -Xml (Get-Content -LiteralPath $taskXml -Raw -Encoding UTF8) `
      -Force | Out-Null
  }
}

Write-Host '恢复完成。RDP 端口和部分安全策略将在重启后完全生效。' -ForegroundColor Green
if ($Reboot) {
  Restart-Computer -Force
} else {
  Write-Host '确认云厂商防火墙已放行恢复后的端口，然后手动重启 Windows。' -ForegroundColor Yellow
}
'@
}

function Write-RestoreScript {
  [CmdletBinding(SupportsShouldProcess)]
  param([Parameter(Mandatory)][string]$BackupPath)

  if (-not $PSCmdlet.ShouldProcess($BackupPath, '写入安全配置恢复脚本')) { return }
  Set-Content -LiteralPath (Join-Path $BackupPath 'restore.ps1') -Value (Get-RestoreSource) -Encoding UTF8
}

function Get-RdpPortCleanupSource {
  return @'
#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$taskName = 'VpsSecurityBootstrap-RdpPort-Cleanup'
$scriptPath = Join-Path $env:ProgramData 'VpsSecurityBootstrap\rdp-port-cleanup.ps1'

for ($attempt = 1; $attempt -le 12; $attempt++) {
  try {
    Get-NetFirewallRule -Name 'VpsSecurity-RdpAllow-Current-*' -ErrorAction SilentlyContinue |
      Remove-NetFirewallRule -ErrorAction Stop
    break
  } catch {
    if ($attempt -eq 12) { throw }
    Start-Sleep -Seconds 5
  }
}

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
'@
}

function Install-RdpPortCleanup {
  param(
    [Parameter(Mandatory)][int]$CurrentPort,
    [Parameter(Mandatory)][int]$TargetPort
  )

  Unregister-ScheduledTask -TaskName $script:RdpPortCleanupTaskName -Confirm:$false -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $script:RdpPortCleanupPath -Force -ErrorAction SilentlyContinue
  if ($CurrentPort -eq $TargetPort) { return }

  Protect-DataDirectory
  Set-Content -LiteralPath $script:RdpPortCleanupPath -Value (Get-RdpPortCleanupSource) -Encoding UTF8
  $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $taskCommand = "`"$powerShellPath`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$($script:RdpPortCleanupPath)`""
  Invoke-NativeCommand -FilePath 'schtasks.exe' -ArgumentList @(
    '/Create', '/TN', $script:RdpPortCleanupTaskName,
    '/SC', 'ONSTART', '/DELAY', '0000:30',
    '/TR', $taskCommand,
    '/RU', 'SYSTEM', '/RL', 'HIGHEST', '/F'
  ) | Out-Null
  Write-Info "重启后将自动删除旧 RDP 端口 $CurrentPort 的临时放行规则。"
}

function Get-TelegramNotifierSource {
  return @'
#requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateSet('Test', 'Login', 'Ban', 'Unban')]
  [string]$NotificationType,

  [string]$ConfigPath = (Join-Path $env:ProgramData 'VpsSecurityBootstrap\telegram.json'),
  [string]$UserName = '-',
  [string]$Address = '-',
  [int]$Port = 0,
  [int]$FailureCount = 0,
  [string]$BanUntil = '-'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function ConvertTo-HtmlText {
  param([AllowEmptyString()][string]$Text)
  if ($null -eq $Text) { return '' }
  return [Security.SecurityElement]::Escape($Text)
}

if (-not (Test-Path -LiteralPath $ConfigPath)) { exit 0 }
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$vpsName = ConvertTo-HtmlText ([string]$config.vpsName)
$computerName = ConvertTo-HtmlText $env:COMPUTERNAME
$safeUser = ConvertTo-HtmlText $UserName
$safeAddress = ConvertTo-HtmlText $Address
$safeUntil = ConvertTo-HtmlText $BanUntil
try {
  $chinaTime = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, 'China Standard Time')
  $timeText = $chinaTime.ToString('yyyy-MM-dd HH:mm:ss') + ' 北京时间 (UTC+8)'
} catch {
  $timeText = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC'
}

switch ($NotificationType) {
  'Test' {
    $text = "✅ <b>Windows Telegram 通知测试成功</b>`nVPS：$vpsName`n主机：$computerName`n时间：$timeText"
  }
  'Login' {
    $text = "✅ <b>Windows RDP 登录成功</b>`nVPS：$vpsName`n主机：$computerName`n用户：$safeUser`n来源 IP：$safeAddress`nRDP 端口：$Port`n时间：$timeText"
  }
  'Ban' {
    $text = "⛔ <b>Windows RDP 爆破来源已封禁</b>`nVPS：$vpsName`n主机：$computerName`n来源 IP：$safeAddress`n失败次数：$FailureCount`nRDP 端口：$Port`n封禁至：$safeUntil`n时间：$timeText"
  }
  'Unban' {
    $text = "♻️ <b>Windows RDP 来源已解除封禁</b>`nVPS：$vpsName`n主机：$computerName`n来源 IP：$safeAddress`nRDP 端口：$Port`n时间：$timeText"
  }
}

$uri = "https://api.telegram.org/bot$([string]$config.token)/sendMessage"
try {
  $response = Invoke-RestMethod `
    -Uri $uri `
    -Method Post `
    -Body @{
      chat_id = [string]$config.chatId
      text = $text
      parse_mode = 'HTML'
      disable_web_page_preview = 'true'
      protect_content = 'true'
    } `
    -ContentType 'application/x-www-form-urlencoded' `
    -TimeoutSec 10
} catch {
  throw 'Telegram API 请求失败；请检查 Token、Chat ID、网络以及是否已向机器人发送 /start。'
}
if (-not $response.ok) { throw 'Telegram API 未返回成功状态。' }
'@
}

function Get-TelegramLoginWatcherSource {
  return @'
#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$dataRoot = Join-Path $env:ProgramData 'VpsSecurityBootstrap'
$statePath = Join-Path $dataRoot 'telegram-rdp-login-state.json'
$notifierPath = Join-Path $dataRoot 'telegram-notify.ps1'
$errorLogPath = Join-Path $dataRoot 'telegram-error.log'
$rdpRegistryPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
$mutex = [Threading.Mutex]::new($false, 'Global\VpsSecurityBootstrap-Telegram-RdpLogin')

function Write-ErrorLog {
  param([string]$Text)
  if (Test-Path -LiteralPath $errorLogPath) {
    $logFile = Get-Item -LiteralPath $errorLogPath -ErrorAction SilentlyContinue
    if ($logFile -and $logFile.Length -ge 1MB) {
      Move-Item -LiteralPath $errorLogPath -Destination "$errorLogPath.1" -Force
    }
  }
  Add-Content -LiteralPath $errorLogPath -Value "$(Get-Date -Format o) $Text" -Encoding UTF8
}

function Save-State {
  param([long]$RecordId)
  $temporary = "$statePath.tmp"
  @{ lastRecordId = $RecordId } | ConvertTo-Json | Set-Content -LiteralPath $temporary -Encoding UTF8
  Move-Item -LiteralPath $temporary -Destination $statePath -Force
}

if (-not $mutex.WaitOne(30000)) { exit 0 }
try {
  if (-not (Test-Path -LiteralPath $notifierPath)) { exit 0 }
  $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4624 } -MaxEvents 100 -ErrorAction SilentlyContinue)
  if ($events.Count -eq 0) { exit 0 }

  if (-not (Test-Path -LiteralPath $statePath)) {
    Save-State -RecordId ([long]$events[0].RecordId)
    exit 0
  }
  try {
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $lastRecordId = [long]$state.lastRecordId
  } catch {
    Save-State -RecordId ([long]$events[0].RecordId)
    Write-ErrorLog "登录通知状态已重置：$($_.Exception.Message)"
    exit 0
  }

  $rdpPort = [int](Get-ItemPropertyValue -Path $rdpRegistryPath -Name PortNumber)
  $newEvents = @($events | Where-Object { [long]$_.RecordId -gt $lastRecordId } | Sort-Object RecordId)
  foreach ($eventRecord in $newEvents) {
    [xml]$eventXml = $eventRecord.ToXml()
    $fields = @{}
    foreach ($field in $eventXml.Event.EventData.Data) {
      $fields[[string]$field.Name] = [string]$field.'#text'
    }

    if ([string]$fields.LogonType -eq '10') {
      $userName = "$(if ($fields.TargetDomainName -and $fields.TargetDomainName -ne '-') { "$($fields.TargetDomainName)\" })$($fields.TargetUserName)"
      $address = [string]$fields.IpAddress
      if ([string]::IsNullOrWhiteSpace($address)) { $address = '-' }
      & $notifierPath -NotificationType Login -UserName $userName -Address $address -Port $rdpPort | Out-Null
    }
    Save-State -RecordId ([long]$eventRecord.RecordId)
  }
} catch {
  Write-ErrorLog "RDP 登录通知失败：$($_.Exception.Message)"
  exit 1
} finally {
  $mutex.ReleaseMutex()
  $mutex.Dispose()
}
'@
}

function Install-TelegramNotification {
  param([Parameter(Mandatory)][object]$Configuration)

  Write-Title '配置 Windows Telegram 通知'
  Protect-DataDirectory
  Set-Content -LiteralPath $script:TelegramNotifierPath -Value (Get-TelegramNotifierSource) -Encoding UTF8
  Set-Content -LiteralPath $script:TelegramLoginWatcherPath -Value (Get-TelegramLoginWatcherSource) -Encoding UTF8

  $temporaryConfig = Join-Path $script:DataRoot "telegram.$([guid]::NewGuid().ToString('N')).tmp"
  try {
    [ordered]@{
      token = [string]$Configuration.token
      chatId = [string]$Configuration.chatId
      vpsName = [string]$Configuration.vpsName
    } | ConvertTo-Json | Set-Content -LiteralPath $temporaryConfig -Encoding UTF8
    Move-Item -LiteralPath $temporaryConfig -Destination $script:TelegramConfigPath -Force
  } finally {
    Remove-Item -LiteralPath $temporaryConfig -Force -ErrorAction SilentlyContinue
  }

  Invoke-NativeCommand -FilePath 'auditpol.exe' -ArgumentList @(
    '/set', "/subcategory:$($script:AuditLogonGuid)", '/success:enable', '/failure:enable'
  ) | Out-Null

  $latestLogon = Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4624 } -MaxEvents 1 -ErrorAction SilentlyContinue
  $latestRecordId = if ($latestLogon) { [long]$latestLogon.RecordId } else { 0L }
  @{ lastRecordId = $latestRecordId } | ConvertTo-Json |
    Set-Content -LiteralPath $script:TelegramLoginStatePath -Encoding UTF8

  $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $taskCommand = "`"$powerShellPath`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$($script:TelegramLoginWatcherPath)`""
  Invoke-NativeCommand -FilePath 'schtasks.exe' -ArgumentList @(
    '/Create', '/TN', $script:TelegramLoginTaskName,
    '/SC', 'ONEVENT', '/EC', 'Security',
    '/MO', "*[System[(EventID=4624)] and EventData[Data[@Name='LogonType']='10']]",
    '/TR', $taskCommand,
    '/RU', 'SYSTEM', '/RL', 'HIGHEST', '/F'
  ) | Out-Null
  Invoke-NativeCommand -FilePath 'schtasks.exe' -ArgumentList @(
    '/Create', '/TN', $script:TelegramLoginCleanupTaskName,
    '/SC', 'MINUTE', '/MO', '5',
    '/TR', $taskCommand,
    '/RU', 'SYSTEM', '/RL', 'HIGHEST', '/F'
  ) | Out-Null
  $taskSettings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
    -StartWhenAvailable
  Set-ScheduledTask -TaskName $script:TelegramLoginTaskName -Settings $taskSettings | Out-Null
  Set-ScheduledTask -TaskName $script:TelegramLoginCleanupTaskName -Settings $taskSettings | Out-Null
  Write-Success 'Telegram 测试成功；RDP 登录、封禁和解封通知已启用'
}

function Remove-TelegramNotification {
  [CmdletBinding(SupportsShouldProcess)]
  param()

  if (-not $PSCmdlet.ShouldProcess($script:DataRoot, '移除 Telegram 通知配置和计划任务')) { return }
  Unregister-ScheduledTask -TaskName $script:TelegramLoginTaskName -Confirm:$false -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $script:TelegramLoginCleanupTaskName -Confirm:$false -ErrorAction SilentlyContinue
  foreach ($path in @(
    $script:TelegramConfigPath,
    $script:TelegramNotifierPath,
    $script:TelegramLoginWatcherPath,
    $script:TelegramLoginStatePath,
    (Join-Path $script:DataRoot 'telegram-error.log'),
    (Join-Path $script:DataRoot 'telegram-error.log.1')
  )) {
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
  }
}

function Get-RdpGuardSource {
  return @'
#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$dataRoot = Join-Path $env:ProgramData 'VpsSecurityBootstrap'
$configPath = Join-Path $dataRoot 'rdp-guard.json'
$statePath = Join-Path $dataRoot 'rdp-guard-state.json'
$logPath = Join-Path $dataRoot 'rdp-guard.log'
$notifierPath = Join-Path $dataRoot 'telegram-notify.ps1'
$firewallGroup = 'VpsSecurityBootstrap'
$mutex = [Threading.Mutex]::new($false, 'Global\VpsSecurityBootstrap-RdpGuard')

function Write-GuardLog {
  param([string]$Text)
  if (Test-Path -LiteralPath $logPath) {
    $logFile = Get-Item -LiteralPath $logPath -ErrorAction SilentlyContinue
    if ($logFile -and $logFile.Length -ge 1MB) {
      Move-Item -LiteralPath $logPath -Destination "$logPath.1" -Force
    }
  }
  Add-Content -LiteralPath $logPath -Value "$(Get-Date -Format o) $Text" -Encoding UTF8
}

function Test-AddressInNetwork {
  param([string]$Address, [string]$Network)
  $ip = $null
  if (-not [Net.IPAddress]::TryParse($Address, [ref]$ip)) { return $false }

  $parts = $Network.Split('/')
  $base = $null
  if (-not [Net.IPAddress]::TryParse($parts[0], [ref]$base)) { return $false }
  if ($ip.AddressFamily -ne $base.AddressFamily) { return $false }
  if ($parts.Count -eq 1) { return $ip.Equals($base) }

  $prefix = [int]$parts[1]
  $ipBytes = $ip.GetAddressBytes()
  $baseBytes = $base.GetAddressBytes()
  $fullBytes = [Math]::Floor($prefix / 8)
  $remainingBits = $prefix % 8
  for ($index = 0; $index -lt $fullBytes; $index++) {
    if ($ipBytes[$index] -ne $baseBytes[$index]) { return $false }
  }
  if ($remainingBits -gt 0) {
    $mask = (0xff -shl (8 - $remainingBits)) -band 0xff
    if (($ipBytes[$fullBytes] -band $mask) -ne ($baseBytes[$fullBytes] -band $mask)) {
      return $false
    }
  }
  return $true
}

function Test-TrustedAddress {
  param([string]$Address, [object[]]$TrustedAddresses)
  foreach ($trusted in $TrustedAddresses) {
    if (Test-AddressInNetwork -Address $Address -Network ([string]$trusted)) { return $true }
  }
  return $false
}

function Get-RuleSuffix {
  param([string]$Address)
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Address)
    return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').Substring(0, 16)
  } finally {
    $sha.Dispose()
  }
}

function Save-State {
  param([hashtable]$Bans)
  $tempPath = "$statePath.tmp"
  [ordered]@{ bans = $Bans } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tempPath -Encoding UTF8
  Move-Item -LiteralPath $tempPath -Destination $statePath -Force
}

if (-not $mutex.WaitOne(30000)) { exit 0 }
try {
  if (-not (Test-Path -LiteralPath $configPath)) { exit 0 }
  $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $protectedPorts = if ($config.PSObject.Properties.Name -contains 'protectedPorts') {
    @($config.protectedPorts | ForEach-Object { [int]$_ })
  } else {
    @([int]$config.rdpPort)
  }
  $now = Get-Date
  $bans = @{}

  if (Test-Path -LiteralPath $statePath) {
    try {
      $saved = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($property in $saved.bans.PSObject.Properties) {
        $bans[$property.Name] = [string]$property.Value
      }
    } catch {
      Write-GuardLog "忽略损坏的状态文件：$($_.Exception.Message)"
    }
  }

  foreach ($address in @($bans.Keys)) {
    if ([datetime]$bans[$address] -le $now) {
      $suffix = Get-RuleSuffix -Address $address
      Get-NetFirewallRule -Name "VpsSecurity-RdpBlock-$suffix-*" -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
      $bans.Remove($address)
      Write-GuardLog "解除封禁：$address"
      if (Test-Path -LiteralPath $notifierPath) {
        try {
          & $notifierPath -NotificationType Unban -Address $address -Port ([int]$config.rdpPort) | Out-Null
        } catch {
          Write-GuardLog "Telegram 解封通知失败：$($_.Exception.Message)"
        }
      }
    }
  }

  $since = $now.AddMinutes(-[int]$config.windowMinutes)
  $counts = @{}
  $events = Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4625; StartTime = $since } -ErrorAction SilentlyContinue
  foreach ($eventRecord in @($events)) {
    [xml]$eventXml = $eventRecord.ToXml()
    $fields = @{}
    foreach ($field in $eventXml.Event.EventData.Data) {
      $fields[[string]$field.Name] = [string]$field.'#text'
    }

    # Only RemoteInteractive (10) identifies an RDP sign-in. Logon type 3 is
    # a generic network sign-in (for example SMB), so counting it here can
    # incorrectly ban a legitimate client from RDP.
    if ($fields.LogonType -ne '10') { continue }
    $status = ([string]$fields.Status).ToLowerInvariant()
    $subStatus = ([string]$fields.SubStatus).ToLowerInvariant()
    $passwordFailure = @('0xc0000064', '0xc000006a', '0xc000006d')
    if ($status -notin $passwordFailure -and $subStatus -notin $passwordFailure) { continue }

    $address = [string]$fields.IpAddress
    if ([string]::IsNullOrWhiteSpace($address) -or $address -in @('-', '127.0.0.1', '::1', '0.0.0.0', '::')) { continue }
    $parsedAddress = $null
    if (-not [Net.IPAddress]::TryParse($address, [ref]$parsedAddress)) { continue }
    $address = $parsedAddress.ToString()
    if (Test-TrustedAddress -Address $address -TrustedAddresses @($config.trustedAddresses)) { continue }

    if (-not $counts.ContainsKey($address)) { $counts[$address] = 0 }
    $counts[$address]++
  }

  foreach ($address in $counts.Keys) {
    if ($counts[$address] -lt [int]$config.threshold) { continue }
    if ($bans.ContainsKey($address) -and [datetime]$bans[$address] -gt $now) { continue }
    $expires = $now.AddMinutes([int]$config.banMinutes)
    $suffix = Get-RuleSuffix -Address $address

    Get-NetFirewallRule -Name "VpsSecurity-RdpBlock-$suffix-*" -ErrorAction SilentlyContinue |
      Remove-NetFirewallRule -ErrorAction SilentlyContinue
    foreach ($protocol in @('TCP', 'UDP')) {
      New-NetFirewallRule `
        -Name "VpsSecurity-RdpBlock-$suffix-$protocol" `
        -DisplayName "VPS Security - RDP block $address ($protocol)" `
        -Group $firewallGroup `
        -Direction Inbound `
        -Action Block `
        -Enabled True `
        -Profile Any `
        -Protocol $protocol `
        -LocalPort $protectedPorts `
        -RemoteAddress $address | Out-Null
    }
    $bans[$address] = $expires.ToString('o')
    Write-GuardLog "封禁：$address；失败次数：$($counts[$address])；到期：$($expires.ToString('o'))"
    if (Test-Path -LiteralPath $notifierPath) {
      try {
        & $notifierPath `
          -NotificationType Ban `
          -Address $address `
          -Port ([int]$config.rdpPort) `
          -FailureCount ([int]$counts[$address]) `
          -BanUntil $expires.ToString('o') | Out-Null
      } catch {
        Write-GuardLog "Telegram 封禁通知失败：$($_.Exception.Message)"
      }
    }
  }

  Save-State -Bans $bans
} catch {
  Write-GuardLog "运行失败：$($_.Exception.Message)"
  exit 1
} finally {
  $mutex.ReleaseMutex()
  $mutex.Dispose()
}
'@
}

function Install-RdpGuard {
  param(
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][int[]]$ProtectedPorts,
    [Parameter(Mandatory)][string[]]$TrustedAddresses,
    [Parameter(Mandatory)][int]$Threshold,
    [Parameter(Mandatory)][int]$WindowMinutes,
    [Parameter(Mandatory)][int]$BlockMinutes
  )

  Write-Title '安装事件驱动的 RDP Guard'
  Protect-DataDirectory
  Set-Content -LiteralPath $script:GuardPath -Value (Get-RdpGuardSource) -Encoding UTF8

  $config = [ordered]@{
    rdpPort = $Port
    protectedPorts = @($ProtectedPorts | Select-Object -Unique)
    trustedAddresses = @($TrustedAddresses)
    threshold = $Threshold
    windowMinutes = $WindowMinutes
    banMinutes = $BlockMinutes
  }
  $config | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $script:GuardConfigPath -Encoding UTF8

  Invoke-NativeCommand -FilePath 'auditpol.exe' -ArgumentList @(
    '/set', "/subcategory:$($script:AuditLogonGuid)", '/failure:enable'
  ) | Out-Null

  $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $taskCommand = "`"$powerShellPath`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$($script:GuardPath)`""
  Invoke-NativeCommand -FilePath 'schtasks.exe' -ArgumentList @(
    '/Create', '/TN', $script:GuardTaskName,
    '/SC', 'ONEVENT', '/EC', 'Security',
    '/MO', '*[System[(EventID=4625)]]',
    '/TR', $taskCommand,
    '/RU', 'SYSTEM', '/RL', 'HIGHEST', '/F'
  ) | Out-Null
  Invoke-NativeCommand -FilePath 'schtasks.exe' -ArgumentList @(
    '/Create', '/TN', $script:GuardCleanupTaskName,
    '/SC', 'MINUTE', '/MO', '5',
    '/TR', $taskCommand,
    '/RU', 'SYSTEM', '/RL', 'HIGHEST', '/F'
  ) | Out-Null

  $taskSettings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
    -StartWhenAvailable
  Set-ScheduledTask -TaskName $script:GuardTaskName -Settings $taskSettings | Out-Null
  Set-ScheduledTask -TaskName $script:GuardCleanupTaskName -Settings $taskSettings | Out-Null

  Write-Success "RDP Guard 已启用：$WindowMinutes 分钟内失败 $Threshold 次，封禁 $BlockMinutes 分钟"
}

function Remove-RdpGuard {
  [CmdletBinding(SupportsShouldProcess)]
  param()

  if (-not $PSCmdlet.ShouldProcess($script:DataRoot, '移除 RDP Guard 配置、计划任务和封禁规则')) { return }
  Unregister-ScheduledTask -TaskName $script:GuardTaskName -Confirm:$false -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $script:GuardCleanupTaskName -Confirm:$false -ErrorAction SilentlyContinue
  Get-NetFirewallRule -Name 'VpsSecurity-RdpBlock-*' -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $script:GuardPath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $script:GuardConfigPath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $script:GuardStatePath -Force -ErrorAction SilentlyContinue
}

function Set-RdpFirewallRule {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][int]$CurrentPort,
    [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RemoteAddresses
  )

  if (-not $PSCmdlet.ShouldProcess("RDP TCP/UDP 端口 $Port", '更新 Windows 防火墙规则')) { return }
  Write-Title '配置 Windows 防火墙'
  Set-NetFirewallProfile -Name Domain, Private, Public -Enabled True -DefaultInboundAction Block

  Get-NetFirewallRule -Name 'VpsSecurity-RdpAllow-*' -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue

  $remote = if ($RemoteAddresses.Count -gt 0) { $RemoteAddresses } else { @('Any') }
  foreach ($protocol in @('TCP', 'UDP')) {
    New-NetFirewallRule `
      -Name "VpsSecurity-RdpAllow-$protocol" `
      -DisplayName "VPS Security - RDP $Port ($protocol)" `
      -Group $script:FirewallGroup `
      -Direction Inbound `
      -Action Allow `
      -Enabled True `
      -Profile Any `
      -Protocol $protocol `
      -LocalPort $Port `
      -RemoteAddress $remote | Out-Null
  }

  if ($CurrentPort -ne $Port) {
    foreach ($protocol in @('TCP', 'UDP')) {
      New-NetFirewallRule `
        -Name "VpsSecurity-RdpAllow-Current-$protocol" `
        -DisplayName "VPS Security - temporary current RDP $CurrentPort ($protocol)" `
        -Group $script:FirewallGroup `
        -Direction Inbound `
        -Action Allow `
        -Enabled True `
        -Profile Any `
        -Protocol $protocol `
        -LocalPort $CurrentPort `
        -RemoteAddress $remote | Out-Null
    }
    Write-Info "重启前仍临时放行当前 RDP 端口：$CurrentPort"
  }

  if ($RemoteAddresses.Count -gt 0) {
    Write-Success "仅允许以下来源访问 RDP：$($RemoteAddresses -join ', ')"
  } else {
    Write-Success 'RDP 防火墙来源为 Any；将依靠 RDP Guard 和账户策略限制爆破'
  }
}

function Set-RdpSecuritySetting {
  [CmdletBinding(SupportsShouldProcess)]
  param([Parameter(Mandatory)][int]$Port)

  if (-not $PSCmdlet.ShouldProcess("RDP 端口 $Port", '更新 RDP、NLA 和加密策略')) { return }
  Write-Title '配置 RDP、NLA 和加密策略'
  New-Item -Path $script:TerminalServerPolicyPath -Force | Out-Null
  New-Item -Path $script:RemoteAssistancePath -Force | Out-Null
  New-ItemProperty -Path $script:TerminalServerPath -Name fDenyTSConnections -PropertyType DWord -Value 0 -Force | Out-Null
  New-ItemProperty -Path $script:RdpRegistryPath -Name PortNumber -PropertyType DWord -Value $Port -Force | Out-Null
  New-ItemProperty -Path $script:RdpRegistryPath -Name UserAuthentication -PropertyType DWord -Value 1 -Force | Out-Null
  New-ItemProperty -Path $script:RdpRegistryPath -Name SecurityLayer -PropertyType DWord -Value 2 -Force | Out-Null
  New-ItemProperty -Path $script:RdpRegistryPath -Name MinEncryptionLevel -PropertyType DWord -Value 3 -Force | Out-Null
  New-ItemProperty -Path $script:TerminalServerPolicyPath -Name UserAuthentication -PropertyType DWord -Value 1 -Force | Out-Null
  New-ItemProperty -Path $script:RemoteAssistancePath -Name fAllowToGetHelp -PropertyType DWord -Value 0 -Force | Out-Null
  Write-Success '已要求 NLA、TLS 安全层和高加密，并关闭远程协助'
}

function Set-TemporaryAccountLockoutPolicy {
  [CmdletBinding(SupportsShouldProcess)]
  param()

  if (-not $PSCmdlet.ShouldProcess('本地账户策略', '设置临时账户锁定策略')) { return }
  Write-Title '配置本地账户临时锁定策略'
  Invoke-NativeCommand -FilePath 'net.exe' -ArgumentList @('accounts', '/lockoutthreshold:10') | Out-Null
  Invoke-NativeCommand -FilePath 'net.exe' -ArgumentList @('accounts', '/lockoutduration:15') | Out-Null
  Invoke-NativeCommand -FilePath 'net.exe' -ArgumentList @('accounts', '/lockoutwindow:15') | Out-Null
  Write-Success '连续失败 10 次后锁定 15 分钟，并在 15 分钟后重置失败计数'
}

function Get-WindowsUpdateStatus {
  $policy = Get-ItemProperty -Path $script:WindowsUpdateAuPolicyPath -ErrorAction SilentlyContinue
  $noAutoUpdate = $null
  if ($policy -and $policy.PSObject.Properties.Name -contains 'NoAutoUpdate') {
    $noAutoUpdate = [int]$policy.NoAutoUpdate
  }
  $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='wuauserv'" -ErrorAction Stop

  return [pscustomobject]@{
    PolicyDisablesAutomaticUpdates = ($noAutoUpdate -eq 1)
    PolicyValue = $noAutoUpdate
    ServiceStartMode = $service.StartMode
    ServiceState = $service.State
  }
}

function Show-WindowsUpdateStatus {
  Assert-SupportedWindows
  $status = Get-WindowsUpdateStatus
  Write-Title 'Windows Update 状态'
  Write-Output "自动更新策略：$(if ($status.PolicyDisablesAutomaticUpdates) { '已由本脚本禁用（NoAutoUpdate=1）' } else { '未由本脚本禁用' })"
  Write-Output "Windows Update 服务：启动类型 $($status.ServiceStartMode)，当前状态 $($status.ServiceState)"
  if ($status.PolicyDisablesAutomaticUpdates) {
    Write-WarningLine '安全更新将不再自动下载或安装。请自行安排手动更新，并保留足够磁盘空间。'
  }
}

function Set-WindowsAutomaticUpdate {
  [CmdletBinding(SupportsShouldProcess)]
  param([Parameter(Mandatory)][bool]$Disable)

  if ($Disable) {
    if (-not $PSCmdlet.ShouldProcess('Windows Update 自动更新策略和 wuauserv 服务', '禁用自动更新并停止当前服务')) { return }
    New-Item -Path $script:WindowsUpdateAuPolicyPath -Force | Out-Null
    New-ItemProperty `
      -Path $script:WindowsUpdateAuPolicyPath `
      -Name NoAutoUpdate `
      -PropertyType DWord `
      -Value 1 `
      -Force | Out-Null
    Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
    Set-Service -Name wuauserv -StartupType Disabled -ErrorAction Stop
    Write-Success '已禁用 Windows 自动更新，并停止 Windows Update 服务'
    return
  }

  if (-not $PSCmdlet.ShouldProcess('Windows Update 自动更新策略和 wuauserv 服务', '恢复 Windows 默认的按需启动和自动更新行为')) { return }
  Remove-ItemProperty `
    -Path $script:WindowsUpdateAuPolicyPath `
    -Name NoAutoUpdate `
    -ErrorAction SilentlyContinue
  Set-Service -Name wuauserv -StartupType Manual -ErrorAction Stop
  Write-Success '已移除本脚本的自动更新禁用策略，并将 Windows Update 服务恢复为按需启动'
}

function Invoke-WindowsUpdateControl {
  Assert-SupportedWindows
  while ($true) {
    Show-WindowsUpdateStatus
    Write-Host ''
    Write-ColorLine -Text '  1. 禁用 Windows 自动更新（策略 + 停止并禁用 Windows Update 服务）' -Color Yellow
    Write-ColorLine -Text '  2. 恢复 Windows 默认更新行为（移除策略 + 按需启动服务）' -Color Yellow
    Write-ColorLine -Text '  0. 返回主菜单' -Color Yellow
    $choice = Read-Default -Prompt '请选择操作' -Default '0'
    switch ($choice) {
      '1' {
        Write-WarningLine '禁用更新会降低系统安全性；此选项适用于磁盘空间极小且由你自行安排更新维护的 VPS。'
        if (-not (Read-YesNo -Prompt '确认禁用 Windows 自动更新吗？' -Default N)) { continue }
        $backupPath = Save-SecurityBackup
        try {
          Set-WindowsAutomaticUpdate -Disable $true
        } catch {
          Write-TerminatingError "设置 Windows Update 失败。可从管理员控制台运行 $backupPath\restore.ps1 恢复。原始错误：$($_.Exception.Message)"
        }
        Write-Info "备份与恢复脚本：$backupPath\restore.ps1"
      }
      '2' {
        if (-not (Read-YesNo -Prompt '确认恢复 Windows 默认更新行为吗？' -Default N)) { continue }
        $backupPath = Save-SecurityBackup
        try {
          Set-WindowsAutomaticUpdate -Disable $false
        } catch {
          Write-TerminatingError "恢复 Windows Update 失败。可从管理员控制台运行 $backupPath\restore.ps1 恢复。原始错误：$($_.Exception.Message)"
        }
        Write-Info "备份与恢复脚本：$backupPath\restore.ps1"
      }
      '0' { return }
      default { Write-ColorLine -Text '无效选项。' -Color Red }
    }
  }
}

function Show-SecurityStatus {
  Assert-SupportedWindows
  $currentVersion = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  $port = Get-CurrentRdpPort
  $nla = Get-ItemPropertyValue -Path $script:RdpRegistryPath -Name UserAuthentication -ErrorAction SilentlyContinue
  $deny = Get-ItemPropertyValue -Path $script:TerminalServerPath -Name fDenyTSConnections -ErrorAction SilentlyContinue
  $profiles = Get-NetFirewallProfile | Select-Object Name, Enabled, DefaultInboundAction
  $rules = Get-NetFirewallRule -Group $script:FirewallGroup -ErrorAction SilentlyContinue |
    Select-Object Name, Enabled, Direction, Action
  $guardTask = Get-ScheduledTask -TaskName $script:GuardTaskName -ErrorAction SilentlyContinue
  $telegramTask = Get-ScheduledTask -TaskName $script:TelegramLoginTaskName -ErrorAction SilentlyContinue
  $telegramConfigured = Test-Path -LiteralPath $script:TelegramConfigPath

  Write-Title 'Windows 11 VPS 当前状态'
  Write-Output "系统：$($currentVersion.ProductName)（Build $($currentVersion.CurrentBuildNumber)）"
  Write-Output "RDP：$(if ($deny -eq 0) { '已启用' } else { '未启用' })"
  Write-Output "RDP 端口：$port"
  Write-Output "NLA：$(if ($nla -eq 1) { '已要求' } else { '未要求' })"
  Write-Output "RDP Guard：$(if ($guardTask) { $guardTask.State } else { '未安装' })"
  Write-Output "Telegram：$(if ($telegramConfigured -and $telegramTask) { "已配置（任务 $($telegramTask.State)）" } else { '未启用' })"
  $windowsUpdateStatus = Get-WindowsUpdateStatus
  Write-Output "Windows 自动更新：$(if ($windowsUpdateStatus.PolicyDisablesAutomaticUpdates) { '已禁用' } else { '未由本脚本禁用' })"
  Write-Host ''
  Write-Output '防火墙配置：'
  $profiles | Format-Table -AutoSize
  Write-Output '本脚本管理的规则：'
  if ($rules) { $rules | Format-Table -AutoSize } else { Write-Output '  无' }
  Write-Output '账户策略：'
  & net.exe accounts
}

function Get-InteractiveConfiguration {
  $currentPort = Get-CurrentRdpPort

  Write-Title 'Windows 11 RDP 安全向导'
  Write-Info "当前 RDP 端口：$currentPort"
  $suggestedPort = if ($currentPort -eq 3389) { Get-RandomAvailablePort } else { $currentPort }
  $clientAddresses = @(Get-CurrentRdpClientAddress -Port $currentPort)
  if ($clientAddresses.Count -gt 0) {
    Write-Info "检测到当前 RDP 客户端地址：$($clientAddresses -join ', ')"
  }
  Write-WarningLine '修改端口前，请先在云厂商安全组/防火墙放行新端口；脚本不会立即重启。'

  while ($true) {
    $portText = Read-Default -Prompt '新的 RDP 端口' -Default ([string]$suggestedPort)
    $parsedPort = 0
    if ([int]::TryParse($portText, [ref]$parsedPort) -and $parsedPort -ge 1024 -and $parsedPort -le 65535) {
      if (Test-PortAvailable -Port $parsedPort -CurrentPort $currentPort) { break }
      Write-ColorLine -Text "端口 $parsedPort 已被其他程序监听，请换一个端口。" -Color Red
    } else {
      Write-ColorLine -Text '端口必须是 1024 到 65535 之间的整数。' -Color Red
    }
  }

  Write-Host ''
  Write-Info '来源限制最有效：只有固定公网 IP 时才填写；动态 IP 请直接回车。'
  $addressText = Read-Default -Prompt '允许访问 RDP 的固定 IP/CIDR（多个用英文逗号分隔）' -Default 'Any'
  $remoteAddresses = @()
  if ($addressText -notmatch '^(?i:any)$') {
    $remoteAddresses = @(ConvertTo-RemoteAddressList -InputValue @($addressText))
  }
  if ($remoteAddresses.Count -gt 0 -and $clientAddresses.Count -gt 0) {
    $currentClientIsAllowed = $false
    foreach ($clientAddress in $clientAddresses) {
      foreach ($network in $remoteAddresses) {
        if (Test-AddressInNetwork -Address $clientAddress -Network $network) {
          $currentClientIsAllowed = $true
          break
        }
      }
      if ($currentClientIsAllowed) { break }
    }
    if (-not $currentClientIsAllowed) {
      Write-WarningLine '填写的白名单不包含当前检测到的 RDP 客户端地址。重连时可能被防火墙拒绝。'
      if (-not (Read-YesNo -Prompt '仍然继续使用这个来源白名单吗？' -Default N)) {
        Write-TerminatingError '操作已取消；请重新运行并填写正确的固定 IP/CIDR。'
      }
    }
  }

  $useGuard = $true
  if ($remoteAddresses.Count -gt 0) {
    $useGuard = Read-YesNo -Prompt '固定来源已能阻止公网爆破，仍启用 RDP Guard 吗？' -Default N
  } else {
    $useGuard = Read-YesNo -Prompt '启用 RDP Guard 自动封禁爆破来源吗？' -Default Y
  }
  $setAccountPolicy = Read-YesNo -Prompt '采用“失败 10 次、锁定 15 分钟”的账户策略吗？' -Default Y
  $telegram = Get-DesiredTelegramConfiguration

  return [pscustomobject]@{
    Port = $parsedPort
    RemoteAddresses = $remoteAddresses
    UseGuard = $useGuard
    SetAccountPolicy = $setAccountPolicy
    Telegram = $telegram
  }
}

function Invoke-Apply {
  Assert-SupportedWindows
  $currentPort = Get-CurrentRdpPort

  if ($NonInteractive) {
    if (-not $script:RdpPortWasProvided) {
      Write-TerminatingError '非交互模式必须显式提供 -RdpPort。'
    }
    if (-not (Test-PortAvailable -Port $RdpPort -CurrentPort $currentPort)) {
      Write-TerminatingError "端口 $RdpPort 已被其他程序监听。"
    }
    $remoteAddresses = @(ConvertTo-RemoteAddressList -InputValue $AllowedRemoteAddress)
    $useGuard = -not $SkipRdpGuard
    $setAccountPolicy = -not $SkipAccountPolicy
    $telegram = Get-DesiredTelegramConfiguration
    $targetPort = $RdpPort
  } else {
    $configuration = Get-InteractiveConfiguration
    $remoteAddresses = @($configuration.RemoteAddresses)
    $useGuard = $configuration.UseGuard
    $setAccountPolicy = $configuration.SetAccountPolicy
    $telegram = $configuration.Telegram
    $targetPort = $configuration.Port

    Write-Title '执行摘要'
    Write-Output "RDP 端口：$currentPort -> $targetPort"
    Write-Output "允许来源：$(if ($remoteAddresses.Count) { $remoteAddresses -join ', ' } else { 'Any' })"
    Write-Output "NLA/TLS/高加密：启用"
    Write-Output "Windows 防火墙：全部配置文件启用，默认阻止入站"
    Write-Output "RDP Guard：$(if ($useGuard) { "$BanWindowMinutes 分钟失败 $BanThreshold 次，封禁 $BanMinutes 分钟" } else { '不启用' })"
    Write-Output "账户锁定策略：$(if ($setAccountPolicy) { '10 次 / 15 分钟' } else { '保持现状' })"
    Write-Output "Telegram：$(if ($telegram.Enabled) { '登录、封禁、解封通知已选择' } else { '不启用' })"
    Write-Output '自动重启：否'

    if (-not (Read-YesNo -Prompt '确认备份并应用以上配置吗？' -Default N)) {
      Write-Info '操作已取消，系统未被修改。'
      return
    }
  }

  $telegram = Confirm-TelegramConfiguration -Telegram $telegram
  $backupPath = Save-SecurityBackup
  try {
    if ($telegram.Enabled) {
      Install-TelegramNotification -Configuration $telegram.Configuration
    } else {
      Remove-TelegramNotification
      Write-Info 'Telegram 通知未启用。'
    }
    Set-RdpFirewallRule -Port $targetPort -CurrentPort $currentPort -RemoteAddresses $remoteAddresses
    Install-RdpPortCleanup -CurrentPort $currentPort -TargetPort $targetPort
    Set-RdpSecuritySetting -Port $targetPort
    if ($setAccountPolicy) { Set-TemporaryAccountLockoutPolicy }
    if ($useGuard) {
      Install-RdpGuard `
        -Port $targetPort `
        -ProtectedPorts @($currentPort, $targetPort) `
        -TrustedAddresses $remoteAddresses `
        -Threshold $BanThreshold `
        -WindowMinutes $BanWindowMinutes `
        -BlockMinutes $BanMinutes
    } else {
      Remove-RdpGuard
      Write-Info 'RDP Guard 未启用。'
    }
  } catch {
    Write-TerminatingError "应用过程中失败，系统可能已发生部分修改。请从管理员控制台运行 $backupPath\restore.ps1。原始错误：$($_.Exception.Message)"
  }

  Write-Title '配置完成'
  Write-Success "RDP 新端口：$targetPort"
  Write-Info "回滚脚本：$backupPath\restore.ps1"
  Write-WarningLine "先在云厂商安全组放行 TCP/UDP $targetPort，再重启 Windows。"
  Write-WarningLine "重启后使用 mstsc 连接：服务器IP:$targetPort；成功前不要关闭当前 RDP/控制台会话。"
  if ($remoteAddresses.Count -eq 0) {
    Write-WarningLine '未设置固定来源白名单；改端口只能减少扫描噪声，主要防线是 NLA、强密码、RDP Guard 和临时锁定。'
  }
  if ($telegram.Enabled) {
    Write-Success 'Telegram 将通知 RDP 登录成功、来源封禁和解除封禁'
  }

  if ($Reboot) {
    Write-WarningLine '已通过 -Reboot 明确要求立即重启。'
    Restart-Computer -Force
  } elseif (-not $NonInteractive -and (Read-YesNo -Prompt '已确认云防火墙规则，是否现在重启？' -Default N)) {
    Restart-Computer -Force
  }
}

function Invoke-TelegramConfiguration {
  Assert-SupportedWindows
  $telegram = Get-DesiredTelegramConfiguration -RotateOnly
  if (-not $NonInteractive) {
    Write-Title '执行摘要'
    Write-Output "操作：更新 Telegram 登录、封禁和解封通知"
    Write-Output "VPS 名称：$($telegram.Configuration.vpsName)"
    Write-Output 'RDP、端口、防火墙和账户策略：不修改'
    if (-not (Read-YesNo -Prompt '确认发送测试消息并更新 Telegram 配置吗？' -Default N)) {
      Write-Info '操作已取消，系统未被修改。'
      return
    }
  }

  $telegram = Confirm-TelegramConfiguration -Telegram $telegram -RotateOnly
  $backupPath = Save-SecurityBackup
  try {
    if ($telegram.Enabled) {
      Install-TelegramNotification -Configuration $telegram.Configuration
    } else {
      Remove-TelegramNotification
    }
  } catch {
    Write-TerminatingError "Telegram 更新失败，旧配置保持在备份中。可运行 $backupPath\restore.ps1。原始错误：$($_.Exception.Message)"
  }
  if ($telegram.Enabled) {
    Write-Success 'Telegram 配置已更新；未修改 RDP 或其他安全策略'
  } else {
    Write-Success 'Telegram 通知已禁用；未修改 RDP 或其他安全策略'
  }
}

function Show-MainMenu {
  Write-Host ''
  Write-ColorLine -Text "PIKACHU SECURITY BOOTSTRAP $($script:ScriptVersion) · WINDOWS 11" -Color Yellow
  Write-ColorLine -Text '  1. 应用或更新 Windows 11 RDP 安全防护' -Color Yellow
  Write-ColorLine -Text '  2. 查看当前 Windows 11 安全状态' -Color Yellow
  Write-ColorLine -Text '  3. 更换 Telegram Bot Token 或通知目标' -Color Yellow
  Write-ColorLine -Text '  4. Windows Update 自动更新控制（适合小磁盘 VPS）' -Color Yellow
  Write-ColorLine -Text '  0. 退出' -Color Yellow
  return Read-Default -Prompt '请选择操作' -Default '1'
}

if ($MyInvocation.InvocationName -ne '.') {
  try {
    if ($NonInteractive -and $Action -eq 'Menu') { $Action = 'Apply' }
    if ($Action -eq 'Menu') {
      switch (Show-MainMenu) {
        '1' { $Action = 'Apply' }
        '2' { $Action = 'Status' }
        '3' { $Action = 'Telegram' }
        '4' { $Action = 'WindowsUpdate' }
        '0' { Write-Info '已退出，系统未被修改。'; exit 0 }
        default { Write-TerminatingError '无效选项。' }
      }
    }

    switch ($Action) {
      'Apply' { Invoke-Apply }
      'Status' { Show-SecurityStatus }
      'Telegram' { Invoke-TelegramConfiguration }
      'WindowsUpdate' { Invoke-WindowsUpdateControl }
    }
  } catch {
    Write-ColorLine -Text "错误：$($_.Exception.Message)" -Color Red
    exit 1
  }
}
