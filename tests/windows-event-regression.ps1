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
  'Get-NetFirewallPortFilter',
  'Get-NetFirewallAddressFilter',
  'Get-NetFirewallApplicationFilter',
  'Get-NetFirewallServiceFilter',
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
  $global:ciWinEventOldestCalls = 0
  function global:Get-WinEvent {
    [CmdletBinding()]
    param(
      [hashtable]$FilterHashtable,
      [string]$LogName,
      [string]$FilterXPath,
      [switch]$Oldest,
      [int]$MaxEvents
    )
    $events = @($global:ciEvents)
    if ($FilterXPath -match 'EventRecordID > ([0-9]+)') {
      $minimumRecordId = [long]$Matches[1]
      $events = @($events | Where-Object { [long]$_.RecordId -gt $minimumRecordId })
    }
    if ($Oldest) {
      $global:ciWinEventOldestCalls++
      $events = @($events | Sort-Object RecordId)
    } else {
      $events = @($events | Sort-Object RecordId -Descending)
    }
    if ($MaxEvents -gt 0) { $events = @($events | Select-Object -First $MaxEvents) }
    return $events
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

  $global:ciWinEventOldestCalls = 0
  $global:ciEvents = @(102..251 | ForEach-Object {
    $event = [pscustomobject]@{ RecordId = [long]$_; TimeCreated = $occurredAt.AddSeconds($_) }
    $event | Add-Member -MemberType ScriptMethod -Name ToXml -Value { $global:ciLoginEventXml }
    $event
  })
  & $watcherPath
  $pagedState = Get-Content `
    -LiteralPath (Join-Path $dataRoot 'telegram-rdp-login-state.json') `
    -Raw | ConvertFrom-Json
  if ([long]$pagedState.lastRecordId -ne 251L -or $global:ciWinEventOldestCalls -lt 2) {
    throw "Login watcher did not process all paged RDP events: state=$($pagedState.lastRecordId), pages=$global:ciWinEventOldestCalls"
  }
  @{ lastRecordId = 999 } | ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $dataRoot 'telegram-rdp-login-state.json') -Encoding UTF8
  $global:ciEvents = @($loginEvent)
  & $watcherPath
  $resetState = Get-Content `
    -LiteralPath (Join-Path $dataRoot 'telegram-rdp-login-state.json') `
    -Raw | ConvertFrom-Json
  if ([long]$resetState.lastRecordId -ne 101L) {
    throw "Login watcher did not recover after the Security log record IDs reset: $($resetState.lastRecordId)"
  }

  Remove-Item -LiteralPath $notifierPath -Force
  @{
    rdpPort = 44756
    protectedPorts = @(44756)
    trustedAddresses = @()
    threshold = 5
    windowMinutes = 5
    banMinutes = 1440
    offenseWindowDays = 90
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
  $global:ciNewFirewallRuleCalls = 0
  function global:Get-NetFirewallRule {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)]$Remaining)
  }
  function global:New-NetFirewallRule {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)]$Remaining)
    $global:ciNewFirewallRuleCalls++
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
  if ($global:ciNewFirewallRuleCalls -ne 2) {
    throw "RDP Guard did not create both TCP and UDP block rules: $global:ciNewFirewallRuleCalls"
  }
  $global:ciNewFirewallRuleCalls = 0
  $global:ciEvents = @()
  & $guardPath
  if ($global:ciNewFirewallRuleCalls -ne 2) {
    throw "RDP Guard did not repair both missing block rules for an active ban: $global:ciNewFirewallRuleCalls"
  }

  # Windows 11 NLA can reject an RDP credential before a RemoteInteractive
  # session exists. The observed event is type 3 / NtLmSsp / NTLM / IpPort 0.
  Remove-Item -LiteralPath (Join-Path $dataRoot 'rdp-guard-state.json') -Force
  $guardNlaEventXml = '<Event><EventData><Data Name="TargetUserName">Administrator</Data><Data Name="LogonType">3</Data><Data Name="Status">0xc000006d</Data><Data Name="SubStatus">0xc000006a</Data><Data Name="LogonProcessName">NtLmSsp</Data><Data Name="AuthenticationPackageName">NTLM</Data><Data Name="IpAddress">198.51.100.7</Data><Data Name="IpPort">0</Data><Data Name="WorkstationName">B_204</Data></EventData></Event>'
  $global:ciGuardEventXml = $guardNlaEventXml
  $global:ciEvents = @(1..5 | ForEach-Object {
    $event = [pscustomobject]@{ RecordId = [long]$_; TimeCreated = Get-Date }
    $event | Add-Member -MemberType ScriptMethod -Name ToXml -Value { $global:ciGuardEventXml }
    $event
  })
  $global:ciNewFirewallRuleCalls = 0
  & $guardPath
  $nlaState = Get-Content -LiteralPath (Join-Path $dataRoot 'rdp-guard-state.json') -Raw | ConvertFrom-Json
  $nlaProperty = $nlaState.bans.PSObject.Properties['198.51.100.7']
  $nlaBan = if ($nlaProperty) { $nlaProperty.Value } else { $null }
  if ($null -eq $nlaBan -or $global:ciNewFirewallRuleCalls -ne 2) {
    throw "RDP Guard did not block the Windows 11 NLA-shaped type 3 failures: $($nlaState | ConvertTo-Json -Depth 5 -Compress)"
  }

  # A normal network logon has a real remote source port. It must not be
  # treated as RDP merely because it also uses type 3 and NTLM.
  Remove-Item -LiteralPath (Join-Path $dataRoot 'rdp-guard-state.json') -Force
  $guardSmbEventXml = '<Event><EventData><Data Name="TargetUserName">Administrator</Data><Data Name="LogonType">3</Data><Data Name="Status">0xc000006d</Data><Data Name="SubStatus">0xc000006a</Data><Data Name="LogonProcessName">NtLmSsp</Data><Data Name="AuthenticationPackageName">NTLM</Data><Data Name="IpAddress">198.51.100.8</Data><Data Name="IpPort">52144</Data><Data Name="WorkstationName">CLIENT</Data></EventData></Event>'
  $global:ciGuardEventXml = $guardSmbEventXml
  $global:ciNewFirewallRuleCalls = 0
  & $guardPath
  $smbState = Get-Content -LiteralPath (Join-Path $dataRoot 'rdp-guard-state.json') -Raw | ConvertFrom-Json
  $smbProperty = $smbState.bans.PSObject.Properties['198.51.100.8']
  $smbBan = if ($smbProperty) { $smbProperty.Value } else { $null }
  if ($null -ne $smbBan -or $global:ciNewFirewallRuleCalls -ne 0) {
    throw "RDP Guard incorrectly treated an ordinary type 3 network logon as RDP: $($smbState | ConvertTo-Json -Depth 5 -Compress)"
  }

  # Missing source-port evidence is not enough to classify a generic type 3
  # event as RDP. Only the observed Windows 11 NLA IpPort=0 shape is accepted.
  Remove-Item -LiteralPath (Join-Path $dataRoot 'rdp-guard-state.json') -Force
  $global:ciGuardEventXml = '<Event><EventData><Data Name="TargetUserName">Administrator</Data><Data Name="LogonType">3</Data><Data Name="Status">0xc000006d</Data><Data Name="SubStatus">0xc000006a</Data><Data Name="LogonProcessName">NtLmSsp</Data><Data Name="AuthenticationPackageName">NTLM</Data><Data Name="IpAddress">198.51.100.10</Data><Data Name="IpPort" /></EventData></Event>'
  $global:ciNewFirewallRuleCalls = 0
  & $guardPath
  $missingPortState = Get-Content -LiteralPath (Join-Path $dataRoot 'rdp-guard-state.json') -Raw | ConvertFrom-Json
  $missingPortProperty = $missingPortState.bans.PSObject.Properties['198.51.100.10']
  if ($missingPortProperty -or $global:ciNewFirewallRuleCalls -ne 0) {
    throw "RDP Guard accepted a type 3 event without the required IpPort=0 evidence: $($missingPortState | ConvertTo-Json -Depth 5 -Compress)"
  }

  # A damaged state must be replaced by a complete, parseable state file.
  Set-Content -LiteralPath (Join-Path $dataRoot 'rdp-guard-state.json') -Value '{broken' -Encoding UTF8
  $global:ciEvents = @()
  & $guardPath
  $null = Get-Content -LiteralPath (Join-Path $dataRoot 'rdp-guard-state.json') -Raw | ConvertFrom-Json

  # The accumulation window must outlive the 30-day fourth ban so that a
  # fifth offense can actually become permanent after that ban expires.
  $escalationAddress = '198.51.100.9'
  $escalationNow = Get-Date
  @{
    bans = @{
      $escalationAddress = @{
        permanent = $false
        expiresAt = $escalationNow.AddMinutes(-1).ToString('o')
        offenseCount = 4
      }
    }
    offenses = @{
      $escalationAddress = @{
        count = 4
        lastBanAt = $escalationNow.AddDays(-31).ToString('o')
      }
    }
  } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $dataRoot 'rdp-guard-state.json') -Encoding UTF8
  $global:ciGuardEventXml = '<Event><EventData><Data Name="TargetUserName">Administrator</Data><Data Name="LogonType">10</Data><Data Name="Status">0xc000006d</Data><Data Name="SubStatus">0xc000006a</Data><Data Name="IpAddress">198.51.100.9</Data></EventData></Event>'
  $global:ciEvents = @(1..5 | ForEach-Object {
    $event = [pscustomobject]@{ RecordId = [long]$_; TimeCreated = Get-Date }
    $event | Add-Member -MemberType ScriptMethod -Name ToXml -Value { $global:ciGuardEventXml }
    $event
  })
  $global:ciNewFirewallRuleCalls = 0
  & $guardPath
  $permanentState = Get-Content -LiteralPath (Join-Path $dataRoot 'rdp-guard-state.json') -Raw | ConvertFrom-Json
  $permanentProperty = $permanentState.bans.PSObject.Properties[$escalationAddress]
  $permanentBan = if ($permanentProperty) { $permanentProperty.Value } else { $null }
  if ($null -eq $permanentBan -or -not [bool]$permanentBan.permanent -or
      [int]$permanentBan.offenseCount -ne 5 -or $global:ciNewFirewallRuleCalls -ne 2) {
    throw "RDP Guard fifth offense did not become permanent: $($permanentState | ConvertTo-Json -Depth 5 -Compress)"
  }

  if (-not (Test-FirewallLocalPortMatch -LocalPort @('Any') -Port 44756) -or
      -not (Test-FirewallLocalPortMatch -LocalPort @('44000-45000') -Port 44756) -or
      (Test-FirewallLocalPortMatch -LocalPort @('3389') -Port 44756)) {
    throw 'Firewall local-port conflict matching failed.'
  }

  $global:ciFirewallRemoteAddress = 'Any'
  function global:Get-NetFirewallRule {
    [CmdletBinding()]
    param(
      [string[]]$Name,
      [string]$PolicyStore,
      [object[]]$Enabled,
      [object[]]$Direction,
      [object[]]$Action
    )
    return [pscustomobject]@{
      Name = 'Legacy-Rdp-Allow'
      DisplayName = 'Legacy RDP Allow Any'
      Group = 'Legacy'
      PolicyStoreSourceType = 'Local'
    }
  }
  function global:Get-NetFirewallPortFilter {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)]$InputObject)
    process { return [pscustomobject]@{ Protocol = 'TCP'; LocalPort = '44756' } }
  }
  function global:Get-NetFirewallAddressFilter {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)]$InputObject)
    process { return [pscustomobject]@{ RemoteAddress = $global:ciFirewallRemoteAddress } }
  }
  function global:Get-NetFirewallApplicationFilter {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)]$InputObject)
    process { return [pscustomobject]@{ Program = 'Any' } }
  }
  function global:Get-NetFirewallServiceFilter {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)]$InputObject)
    process { return [pscustomobject]@{ Service = 'Any' } }
  }
  $conflicts = @(Get-RdpFirewallConflict -Port 44756)
  if ($conflicts.Count -ne 1 -or $conflicts[0].Name -ne 'Legacy-Rdp-Allow') {
    throw 'A broad unmanaged RDP allow rule was not detected.'
  }
  $global:ciFirewallRemoteAddress = '203.0.113.10'
  if (@(Get-RdpFirewallConflict -Port 44756).Count -ne 1) {
    throw 'An unmanaged allow rule for a different source was not reported as a whitelist conflict.'
  }

  $bootstrapDefinition = Get-Content -LiteralPath $BootstrapPath -Raw -Encoding UTF8
  if ($bootstrapDefinition -match '-MultipleInstances Queue' -or
      ([regex]::Matches($bootstrapDefinition, '-MultipleInstances IgnoreNew')).Count -lt 2) {
    throw 'Event-driven Windows tasks must ignore duplicate triggers instead of queueing PowerShell instances.'
  }
  if ($bootstrapDefinition -notmatch '\[int\]\$BanThreshold = 3' -or
      $bootstrapDefinition -notmatch "'/SC', 'MINUTE', '/MO', '1'" -or
      $bootstrapDefinition -notmatch 'OffenseWindowDays = 90') {
    throw 'RDP Guard must use three failures, a one-minute catch-up sweep, and a reachable permanent-ban window.'
  }
  $watcherSource = Get-TelegramLoginWatcherSource
  if ($watcherSource -notmatch 'EventRecordID > \$lastRecordId' -or
      $watcherSource -notmatch '-Oldest' -or
      $watcherSource -notmatch 'latestEvent\.RecordId -lt \$lastRecordId') {
    throw 'Telegram login watcher must process RDP events incrementally in oldest-first pages.'
  }
  $guardSource = Get-RdpGuardSource
  if ($guardSource -notmatch 'Protect-RdpGuardAddress.*-Repair') {
    throw 'RDP Guard must repair a missing firewall rule for an active ban.'
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
  Remove-Variable `
    ciTelegramBody,ciLoginEventXml,ciGuardEventXml,ciEvents,ciWinEventOldestCalls,ciFirewallRemoteAddress,ciNewFirewallRuleCalls `
    -Scope Global `
    -ErrorAction SilentlyContinue
}
