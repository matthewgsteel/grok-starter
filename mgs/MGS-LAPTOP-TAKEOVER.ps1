$ErrorActionPreference = 'Stop'

$pc = '192.168.1.225'
$user = 'MAIN-GRETNA-PC\Administrator'
$pw = $env:MGS_RESCUE_PASSWORD
if ([string]::IsNullOrWhiteSpace($pw)) { throw 'Set MGS_RESCUE_PASSWORD before running this script.' }

Write-Host 'MGS LAPTOP TAKEOVER' -ForegroundColor Cyan
Write-Host 'No reboot. No Windows repair. Restores the existing MGS public bridge only.' -ForegroundColor DarkGray

# Authenticate to the damaged PC using the temporary built-in Administrator credential.
& net.exe use "\\$pc\IPC$" /delete /y 2>$null | Out-Null
& net.exe use "\\$pc\IPC$" $pw "/user:$user" /persistent:no | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'SMB authentication to MAIN-GRETNA-PC failed.' }
Write-Host 'REMOTE ADMIN AUTHENTICATED.' -ForegroundColor Green

$remoteDir = "\\$pc\C$\ProgramData\MGS-Rescue"
New-Item -ItemType Directory -Force -Path $remoteDir | Out-Null

# Pin the exact reviewed emergency bridge script.
$emergencyUrl = 'https://raw.githubusercontent.com/matthewgsteel/grok-starter/ee3e6af68b67e672374ff5f243e7d50254d038db/mgs/MGS-EMERGENCY-ACCESS.ps1'
$localEmergency = Join-Path $env:TEMP 'MGS-EMERGENCY-ACCESS.ps1'
Invoke-WebRequest -UseBasicParsing -Uri $emergencyUrl -OutFile $localEmergency
Copy-Item -LiteralPath $localEmergency -Destination (Join-Path $remoteDir 'MGS-EMERGENCY-ACCESS.ps1') -Force
Write-Host 'RECOVERY SCRIPT PUSHED TO PC.' -ForegroundColor Green

# Use Microsoft Sysinternals PsExec from the healthy laptop for reliable remote SYSTEM execution.
$toolsZip = Join-Path $env:TEMP 'PSTools.zip'
$toolsDir = Join-Path $env:TEMP 'PSTools-MGS'
if (-not (Test-Path (Join-Path $toolsDir 'PsExec.exe'))) {
    Invoke-WebRequest -UseBasicParsing -Uri 'https://download.sysinternals.com/files/PSTools.zip' -OutFile $toolsZip
    Remove-Item $toolsDir -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -LiteralPath $toolsZip -DestinationPath $toolsDir -Force
}

$psexec = Join-Path $toolsDir 'PsExec.exe'
& $psexec "\\$pc" -u $user -p $pw -s -h -accepteula -nobanner powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\ProgramData\MGS-Rescue\MGS-EMERGENCY-ACCESS.ps1'
$px = $LASTEXITCODE
if ($px -ne 0) { Write-Host ("PsExec exit code: $px") -ForegroundColor Yellow }

Start-Sleep -Seconds 3

# 406 is the expected unauthenticated GET response from a healthy MCP endpoint.
$code = $null
try {
    $r = Invoke-WebRequest -UseBasicParsing -Uri 'https://mcp.matthewgsteel.com/mcp' -TimeoutSec 12
    $code = [int]$r.StatusCode
} catch {
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
        $code = [int]$_.Exception.Response.StatusCode
    } else {
        $code = 'NO_RESPONSE'
    }
}
Write-Host ("PUBLIC MCP HTTP=$code") -ForegroundColor Cyan

$env:MGS_RESCUE_PASSWORD = $null
Write-Host 'TAKEOVER ATTEMPT COMPLETE. Tell ChatGPT: TEST.' -ForegroundColor Green
