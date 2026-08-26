#requires -Version 5.1
<#
.SYNOPSIS
  Downloads, verifies, and starts the Windows security bootstrap from a fixed release.

.EXAMPLE
  irm https://github.com/elonjack/vps-security-bootstrap/releases/latest/download/install.ps1 | iex
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($env:OS -ne 'Windows_NT') {
  throw '此安装器仅适用于 Windows。Debian 请使用 install.sh。'
}

$currentVersion = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
if ([int]$currentVersion.CurrentBuildNumber -lt 22000) {
  throw "仅支持 Windows 11（检测到构建号 $($currentVersion.CurrentBuildNumber)）。"
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$repository = 'elonjack/vps-security-bootstrap'
$releaseVersion = 'v1.3.11'
$expectedScriptSha256 = '49A2B9D0B098EB326BDFFD2670977CF830D507D5241D0527CBA90BC46CE96D03'
$workDirectory = Join-Path ([IO.Path]::GetTempPath()) "vps-security-$releaseVersion-$([guid]::NewGuid().ToString('N'))"
$baseUrl = "https://github.com/$repository/releases/download/$releaseVersion"
$scriptPath = Join-Path $workDirectory 'windows-bootstrap.ps1'

try {
  New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
  Write-Output "正在下载并校验 $releaseVersion..."
  Invoke-WebRequest -Uri "$baseUrl/windows-bootstrap.ps1" -OutFile $scriptPath -UseBasicParsing
  $actual = (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash
  if (-not [string]::Equals($actual, $expectedScriptSha256, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'SHA-256 校验失败，脚本不会运行。'
  }

  Write-Output 'SHA-256 校验成功，正在启动 Windows 安全向导。'
  & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath
  if ($LASTEXITCODE -ne 0) {
    throw "Windows 安全向导失败，退出码：$LASTEXITCODE"
  }
} finally {
  if (Test-Path -LiteralPath $workDirectory) {
    Remove-Item -LiteralPath $workDirectory -Recurse -Force
  }
}
