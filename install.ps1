#requires -Version 5.1
<#
.SYNOPSIS
  Downloads, verifies, and starts the Windows security bootstrap from a fixed release.

.EXAMPLE
  $installer = Join-Path ([IO.Path]::GetTempPath()) 'vps-security-bootstrap-install.ps1'
  Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/elonjack/vps-security-bootstrap/releases/latest/download/install.ps1' -OutFile $installer
  & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installer
  Remove-Item -LiteralPath $installer -Force
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
$releaseVersion = 'v1.3.19'
$expectedScriptSha256 = '1FE54DA1C12558611185FA02BC0AC2CB618A235040C244F11022BF7E29FB9145'
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
  $powerShellPath = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    Join-Path $env:WINDIR 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
  } else {
    Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  }
  if (-not (Test-Path -LiteralPath $powerShellPath)) {
    throw "找不到可用的 Windows PowerShell：$powerShellPath"
  }
  & $powerShellPath -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath
  if ($LASTEXITCODE -ne 0) {
    throw "Windows 安全向导失败，退出码：$LASTEXITCODE"
  }
} finally {
  if (Test-Path -LiteralPath $workDirectory) {
    Remove-Item -LiteralPath $workDirectory -Recurse -Force
  }
}
