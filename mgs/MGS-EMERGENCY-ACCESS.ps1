$ErrorActionPreference = 'Stop'

$root = 'D:\MGS_RECOVERY'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$tunnelId = 'fdede1c4-f1eb-436a-a331-c5202e0cff12'
$cf = 'C:\Program Files (x86)\cloudflared\cloudflared.exe'
$cred = Join-Path $root ($tunnelId + '.json')
$cfg = Join-Path $root 'mgs-emergency-access.yml'
$stdout = Join-Path $root ("MGS_cloudflared_emergency_stdout_$stamp.txt")
$stderr = Join-Path $root ("MGS_cloudflared_emergency_stderr_$stamp.txt")

Write-Host 'MGS EMERGENCY ACCESS' -ForegroundColor Cyan
Write-Host 'Bridge only. No reboot. No Windows repair. No Proton changes. No user-data changes.' -ForegroundColor DarkGray

$listener = Get-NetTCPConnection -LocalPort 8765 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $listener) { throw 'Local MGS MCP is not listening on port 8765.' }
Write-Host ('LOCAL MCP LISTENER CONFIRMED: PID ' + $listener.OwningProcess) -ForegroundColor Green

if (-not (Test-Path $cf)) { throw 'cloudflared.exe is missing from the known installed path.' }
$version = & $cf --version 2>&1
if ($LASTEXITCODE -ne 0) { throw 'cloudflared.exe exists but will not execute.' }
Write-Host ('CLOUDFLARED CONFIRMED: ' + ($version -join ' ')) -ForegroundColor Green

if (-not (Test-Path $cred)) { throw ('Recovered tunnel credential is missing: ' + $cred) }
Write-Host 'RECOVERED TUNNEL CREDENTIAL CONFIRMED.' -ForegroundColor Green

$credYaml = $cred -replace '\\','/'
@(
    "tunnel: $tunnelId",
    "credentials-file: $credYaml",
    'ingress:',
    '  - hostname: mcp.matthewgsteel.com',
    '    service: http://127.0.0.1:8765',
    '  - service: http_status:404'
) | Set-Content -LiteralPath $cfg -Encoding ASCII

# Stop only legacy/recovery replicas for the MGS tunnel. Do not touch Dominican or unrelated tunnels.
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'cloudflared*.exe' } |
    ForEach-Object {
        $cmd = [string]$_.CommandLine
        if ($cmd -like ('*' + $tunnelId + '*') -or $cmd -like '*mgs-recovery-config*' -or $cmd -like '*mgs-emergency-access*') {
            Write-Host ('STOPPING OLD MGS TUNNEL PID ' + $_.ProcessId) -ForegroundColor Yellow
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }

$mgsSvc = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -eq 'Cloudflared MGS MCP Tunnel' -or $_.Name -eq 'Cloudflared MGS MCP Tunnel' } |
    Select-Object -First 1
if ($mgsSvc -and $mgsSvc.State -eq 'Running') {
    Write-Host ('STOPPING LEGACY MGS SERVICE: ' + $mgsSvc.Name) -ForegroundColor Yellow
    Stop-Service -Name $mgsSvc.Name -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 2

# Current Cloudflare documented locally-managed syntax:
# cloudflared tunnel --config <path> run <UUID>
$p = Start-Process -FilePath $cf -ArgumentList @('tunnel','--config',$cfg,'run',$tunnelId) -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 10

if ($p.HasExited) {
    Write-Host ('CLOUDFLARED EXITED WITH CODE ' + $p.ExitCode) -ForegroundColor Red
    Get-Content $stderr -Tail 120 -ErrorAction SilentlyContinue
    throw 'Clean MGS tunnel did not stay running.'
}

Write-Host ('CLEAN MGS TUNNEL RUNNING: PID ' + $p.Id) -ForegroundColor Green
Write-Host ('STDERR LOG: ' + $stderr) -ForegroundColor DarkGray
Write-Host 'DONE. Leave this process alone and tell ChatGPT: TEST.' -ForegroundColor Green
