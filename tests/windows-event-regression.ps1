param([Parameter(Mandatory)][string]$BootstrapPath)

$ErrorActionPreference = 'Stop'
. $BootstrapPath

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('vps-windows-event-regression-' + [guid]::NewGuid().ToString('N'))
$originalProgramData = $env:ProgramData
$mockNames = @(
  'Invoke-RestMethod',
  'Get-WinEvent',
  'Get-ItemPropertyValue',
  'Get-NetFirewallRule',
  'New-NetFirewallRule',
  'Remove-NetFirewallRule'
)
$originalFunctions = @{}
foreach ($name in $mockNames) {
  $originalFunctions[$name] = Get-Item -LiteralPath "Function:\global:$name" -ErrorAction SilentlyContinue
}

try {
  $env:ProgramData = $testRoot
  $dataRoot = Join-Path $testRoot 'VpsSecurityBootstrap'
  New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null

  @{
    token = '123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcd'
    chatId = '123456789'
    vpsName = 'CI-VPS'
  } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dataRoot 'telegram.json') -Encoding UTF8

  $notifierPath = Join-Path $dataRoot 'telegram-notify.ps1'
  Set-Content -LiteralPath $notifierPath -Value (Get-TelegramNotifierSource) -Encoding UTF8
  $global:ciTelegramBody = $null
  function global:Invoke-RestMethod {
    param(
      [string]$Uri,
      [string]$Method,
      [hashtable]$Body,
      [string]$ContentType,
      [int]$TimeoutSec
    )
    $global:ciTelegramBody = $Body
    return [pscustomobject]@{ ok = $true }
  }

  $occurredAt = [datetime]'2026-09-03T20:27:48+08:00'
  & $notifierPath `
    -NotificationType Login `
    -UserName 'DESKTOP\Administrator' `
    -Address '198.51.100.4' `
    -Port 44756 `
    -OccurredAt $occurredAt
  $telegramText = [string]$global:ciTelegramBody['text']
  if ($global:ciTelegramBody['parse_mode'] -ne 'HTML' -or
      $telegramText -notmatch '<b>.*</b>' -or
      $telegramText -notmatch '<code>DESKTOP\\Administrator</code>' -or
      $telegramText -notmatch '<code>198\.51\.100\.4</code>' -or
      $telegramText -notmatch '<code>44756</code>' -or
      $telegramText -notmatch '<code>2026-09-03 20:27:48') {
    throw "Telegram login notification did not preserve the event time and structured layout: $telegramText"
  }

  $watcherPath = Join-Path $dataRoot 'telegram-rdp-login.ps1'
  Set-Content -LiteralPath $watcherPath -Value (Get-TelegramLoginWatcherSource) -Encoding UTF8
  @{ lastRecordId = 100 } | ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $dataRoot 'telegram-rdp-login-state.json') -Encoding UTF8
  $stubNotifier = @'
param([string]$NotificationType,[string]$UserName,[string]$Address,[int]$Port,[datetime]$OccurredAt)
@{ NotificationType = $NotificationType; UserName = $UserName; Address = $Address; Port = $Port; OccurredAt = $OccurredAt.ToString('o') } |
  ConvertTo-Json | Set-Content -LiteralPath (Join-Path $env:ProgramData 'VpsSecurityBootstrap\watcher-capture.json') -Encoding UTF8
'@
  Set-Content -LiteralPath $notifierPath -Value $stubNotifier -Encoding UTF8

  # An empty field does not expose the PowerShell XML adapter's '#text' property.
  # The production watcher must still parse and send this RDP event.
  $loginEventXml = '<Event><EventData><Data Name="TargetUserName">Administrator</Data><Data Name="TargetDomainName">DESKTOP</Data><Data Name="LogonType">10</Data><Data Name="IpAddress">198.51.100.4</Data><Data Name="WorkstationName" /></EventData></Event>'
  $loginEvent = [pscustomobject]@{ RecordId = 101L; TimeCreated = $occurredAt.DateTime }
  $loginEvent | Add-Member -MemberType ScriptMethod -Name ToXml -Value { $global:ciLoginEventXml }
  $global:ciLoginEventXml = $loginEventXml
  $global:ciEvents = @($loginEvent)
  function global:Get-WinEvent {
    [CmdletBinding()]
    param([hashtable]$FilterHashtable, [int]$MaxEvents)
    return $global:ciEvents
  }
  function global:Get-ItemPropertyValue {
    [CmdletBinding()]
    param([string]$Path, [string]$Name)
    return 44756
  }
  & $watcherPath
  $capture = Get-Content -LiteralPath (Join-Path $dataRoot 'watcher-capture.json') -Raw | ConvertFrom-Json
  if ($capture.NotificationType -ne 'Login' -or
      $capture.UserName -ne 'DESKTOP\Administrator' -or
      $capture.Address -ne '198.51.100.4' -or
      $capture.Port -ne 44756 -or
      ([datetime]$capture.OccurredAt) -ne $occurredAt.DateTime) {
    throw "Login watcher did not process the empty-field event: $($capture | ConvertTo-Json -Compress)"
  }

  Remove-Item -LiteralPath $notifierPath -Force
  @{
    rdpPort = 44756
    protectedPorts = @(44756)
    trustedAddresses = @()
    threshold = 5
    windowMinutes = 5
    banMinutes = 1440
    offenseWindowDays = 30
    banDurationsMinutes = @(1440, 4320, 10080, 43200)
    permanentAfter = 5
  } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dataRoot 'rdp-guard.json') -Encoding UTF8
  $guardPath = Join-Path $dataRoot 'rdp-guard.ps1'
  Set-Content -LiteralPath $guardPath -Value (Get-RdpGuardSource) -Encoding UTF8
  $guardEventXml = '<Event><EventData><Data Name="TargetUserName">bad</Data><Data Name="LogonType">10</Data><Data Name="Status">0xc000006d</Data><Data Name="SubStatus">0xc000006a</Data><Data Name="IpAddress">198.51.100.6</Data><Data Name="WorkstationName" /></EventData></Event>'
  $global:ciGuardEventXml = $guardEventXml
  $global:ciEvents = @(1..5 | ForEach-Object {
    $event = [pscustomobject]@{ RecordId = [long]$_; TimeCreated = Get-Date }
    $event | Add-Member -MemberType ScriptMethod -Name ToXml -Value { $global:ciGuardEventXml }
    $event
  })
  function global:Get-NetFirewallRule {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)]$Remaining)
  }
  function global:New-NetFirewallRule {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)]$Remaining)
    return [pscustomobject]@{}
  }
  function global:Remove-NetFirewallRule {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)]$Remaining)
  }
  & $guardPath
  $guardState = Get-Content -LiteralPath (Join-Path $dataRoot 'rdp-guard-state.json') -Raw | ConvertFrom-Json
  $ban = $guardState.bans.PSObject.Properties['198.51.100.6'].Value
  if ($null -eq $ban -or $ban.offenseCount -ne 1 -or $ban.permanent) {
    throw "RDP Guard did not process the empty-field failed-login event: $($guardState | ConvertTo-Json -Depth 5 -Compress)"
  }
} finally {
  $env:ProgramData = $originalProgramData
  foreach ($name in $mockNames) {
    if ($originalFunctions[$name]) {
      Set-Item -LiteralPath "Function:\global:$name" -Value $originalFunctions[$name].ScriptBlock
    } else {
      Remove-Item -LiteralPath "Function:\global:$name" -ErrorAction SilentlyContinue
    }
  }
  Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Variable ciTelegramBody,ciLoginEventXml,ciGuardEventXml,ciEvents -Scope Global -ErrorAction SilentlyContinue
}
