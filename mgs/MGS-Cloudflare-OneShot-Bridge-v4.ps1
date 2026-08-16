$ErrorActionPreference = 'Stop'

$rawUrl = 'https://raw.githubusercontent.com/matthewgsteel/grok-starter/main/mgs/MGS-Cloudflare-OneShot-Bridge-v4.ps1'
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$root = if (Test-Path 'D:\') { 'D:\MGS_RECOVERY' } else { Join-Path $env:TEMP 'MGS_RECOVERY' }
New-Item -ItemType Directory -Force -Path $root | Out-Null
$log = Join-Path $root ("MGS_cloudflare_oneshot_$stamp.log")

function Log([string]$m) {
    $line = "[$(Get-Date -Format o)] $m"
    $line | Tee-Object -FilePath $log -Append
}

function Is-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Is-Admin)) {
    $stage = Join-Path $root 'MGS-Cloudflare-OneShot-Bridge-v4.ps1'
    Invoke-WebRequest -UseBasicParsing -Uri $rawUrl -OutFile $stage
    Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$stage+'"'))
    Write-Host 'Approve the Windows administrator prompt once. The recovery will continue in the elevated window.' -ForegroundColor Yellow
    return
}

Log 'MGS one-shot bridge recovery started. No reboot, no Proton changes, no user-data cleanup.'

# 1. Make sure the local MCP origin exists before touching Cloudflare.
$listen = Get-NetTCPConnection -LocalPort 8765 -State Listen -ErrorAction SilentlyContinue
if (-not $listen) {
    Log 'Port 8765 is not listening. Trying the existing MGS MCP scheduled task.'
    $task = Get-ScheduledTask -TaskName 'MGS MCP Server' -ErrorAction SilentlyContinue
    if ($task) {
        Start-ScheduledTask -TaskName 'MGS MCP Server'
        Start-Sleep -Seconds 4
    }
    $listen = Get-NetTCPConnection -LocalPort 8765 -State Listen -ErrorAction SilentlyContinue
}
if (-not $listen) {
    Log 'Port 8765 is still down. Running the previously created bridge repair once.'
    try {
        Invoke-RestMethod 'https://raw.githubusercontent.com/matthewgsteel/grok-starter/main/mgs/MGS-Repair-MCP-Bridge-v2.ps1' | Invoke-Expression
        Start-Sleep -Seconds 5
    } catch {
        Log ("Bridge repair returned: " + $_.Exception.Message)
    }
    $listen = Get-NetTCPConnection -LocalPort 8765 -State Listen -ErrorAction SilentlyContinue
}
if (-not $listen) {
    Log 'FAIL: local MCP origin on 8765 is not listening. Stopping before Cloudflare changes.'
    throw 'Local MCP origin is unavailable on port 8765.'
}
Log ('Local MCP origin is listening on 8765. PID(s): ' + (($listen | Select-Object -ExpandProperty OwningProcess -Unique) -join ','))

# 2. Locate the best surviving MGS tunnel configuration.
$dirs = @(
    'C:\Windows\System32\config\systemprofile\.cloudflared',
    'C:\Windows.old\Windows\System32\config\systemprofile\.cloudflared',
    'C:\Users\mgste\.cloudflared',
    'C:\Windows.old\Users\mgste\.cloudflared',
    'C:\ProgramData\cloudflared'
) | Where-Object { Test-Path $_ }

$configs = foreach ($d in $dirs) {
    Get-ChildItem -LiteralPath $d -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^config.*\.ya?ml$' }
}

$bestConfig = $null
foreach ($c in $configs) {
    try {
        $t = Get-Content -LiteralPath $c.FullName -Raw -ErrorAction Stop
        if ($t -match '(?i)mcp\.matthewgsteel\.com' -or $t -match '(?i)(127\.0\.0\.1|localhost):8765') {
            $bestConfig = $c
            break
        }
    } catch {}
}
if (-not $bestConfig) {
    $preferred = 'C:\Windows\System32\config\systemprofile\.cloudflared\config.yml'
    if (Test-Path $preferred) { $bestConfig = Get-Item $preferred }
}
if (-not $bestConfig -and $configs) { $bestConfig = $configs | Select-Object -First 1 }
if (-not $bestConfig) {
    Log 'FAIL: no surviving Cloudflare config file was found in the expected current/Windows.old locations.'
    throw 'No Cloudflare config found.'
}
Log ('Using source config: ' + $bestConfig.FullName)
$cfgText = Get-Content -LiteralPath $bestConfig.FullName -Raw

$tunnelId = $null
if ($cfgText -match '(?im)^\s*tunnel\s*:\s*["'']?([0-9a-fA-F-]{36})') { $tunnelId = $matches[1] }

$credRef = $null
if ($cfgText -match '(?im)^\s*credentials-file\s*:\s*["'']?([^\r\n"'']+)') {
    $credRef = $matches[1].Trim()
    $credRef = [Environment]::ExpandEnvironmentVariables($credRef)
    if (-not [IO.Path]::IsPathRooted($credRef)) { $credRef = Join-Path $bestConfig.DirectoryName $credRef }
}

# 3. Resolve the tunnel credential JSON without exposing its secret.
$cred = $null
if ($credRef -and (Test-Path $credRef)) { $cred = Get-Item $credRef }

$jsonCandidates = foreach ($d in $dirs) {
    Get-ChildItem -LiteralPath $d -File -Filter '*.json' -Force -ErrorAction SilentlyContinue
}

if (-not $cred -and $tunnelId) {
    $cred = $jsonCandidates | Where-Object { $_.BaseName -ieq $tunnelId } | Select-Object -First 1
}

if (-not $cred) {
    foreach ($j in $jsonCandidates) {
        try {
            $obj = Get-Content -LiteralPath $j.FullName -Raw | ConvertFrom-Json
            if ($obj.TunnelID) {
                if (-not $tunnelId -or ([string]$obj.TunnelID -ieq $tunnelId)) {
                    $cred = $j
                    if (-not $tunnelId) { $tunnelId = [string]$obj.TunnelID }
                    break
                }
            }
        } catch {}
    }
}

if (-not $cred -or -not $tunnelId) {
    Log 'FAIL: could not pair a tunnel UUID with its credential JSON.'
    throw 'Cloudflare tunnel credentials could not be recovered.'
}
Log ('Recovered tunnel ID ' + $tunnelId + ' and credential file ' + $cred.Name + '. Secret content is not logged.')

$recoveryCred = Join-Path $root ($tunnelId + '.json')
Copy-Item -LiteralPath $cred.FullName -Destination $recoveryCred -Force

# 4. Build an isolated MGS-only recovery config. This avoids broken shared service state.
$recoveryCfg = Join-Path $root 'mgs-recovery-config.yml'
$credYaml = $recoveryCred -replace '\\','/'
@(
    "tunnel: $tunnelId",
    "credentials-file: $credYaml",
    'ingress:',
    '  - hostname: mcp.matthewgsteel.com',
    '    service: http://127.0.0.1:8765',
    '  - service: http_status:404'
) | Set-Content -LiteralPath $recoveryCfg -Encoding ASCII
Log ('Created isolated recovery config: ' + $recoveryCfg)

# 5. Use a known-good cloudflared binary. Prefer the installed binary only if it executes cleanly.
$installed = @(
    'C:\Program Files (x86)\cloudflared\cloudflared.exe',
    'C:\Cloudflared\bin\cloudflared.exe',
    'C:\Windows.old\Program Files (x86)\cloudflared\cloudflared.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1

$exe = $null
if ($installed) {
    try {
        $ver = & $installed --version 2>&1
        if ($LASTEXITCODE -eq 0) {
            $exe = $installed
            Log ('Installed cloudflared executes: ' + ($ver -join ' '))
        }
    } catch {
        Log ('Installed cloudflared failed self-test: ' + $_.Exception.Message)
    }
}

if (-not $exe) {
    $exe = Join-Path $root 'cloudflared.exe'
    Log 'Downloading a fresh official Cloudflare cloudflared binary into the recovery folder.'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe' -OutFile $exe
    $ver = & $exe --version 2>&1
    Log ('Recovery cloudflared executes: ' + ($ver -join ' '))
}

# 6. Validate ingress, then launch a connector directly. Do not stop other tunnels.
$validate = & $exe --config=$recoveryCfg tunnel ingress validate 2>&1
Log ('Ingress validation: ' + ($validate -join ' '))
if ($LASTEXITCODE -ne 0) { throw 'Cloudflare ingress validation failed.' }

$outLog = Join-Path $root ("MGS_cloudflared_stdout_$stamp.txt")
$errLog = Join-Path $root ("MGS_cloudflared_stderr_$stamp.txt")
$p = Start-Process -FilePath $exe -ArgumentList @("--config=$recoveryCfg",'tunnel','run') -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 10

if ($p.HasExited) {
    $err = (Get-Content -LiteralPath $errLog -Tail 80 -ErrorAction SilentlyContinue) -join "`n"
    Log ('First tunnel launch exited with code ' + $p.ExitCode)
    Log ('First tunnel stderr tail: ' + $err)

    # QUIC/UDP transport failures are common enough to justify one HTTP/2 fallback.
    Add-Content -LiteralPath $recoveryCfg -Value 'protocol: http2'
    $outLog2 = Join-Path $root ("MGS_cloudflared_http2_stdout_$stamp.txt")
    $errLog2 = Join-Path $root ("MGS_cloudflared_http2_stderr_$stamp.txt")
    $p = Start-Process -FilePath $exe -ArgumentList @("--config=$recoveryCfg",'tunnel','run') -RedirectStandardOutput $outLog2 -RedirectStandardError $errLog2 -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 10
    if ($p.HasExited) {
        $err2 = (Get-Content -LiteralPath $errLog2 -Tail 100 -ErrorAction SilentlyContinue) -join "`n"
        Log ('HTTP/2 fallback exited with code ' + $p.ExitCode)
        Log ('HTTP/2 stderr tail: ' + $err2)
        throw 'cloudflared could not stay connected. Exact errors are preserved in the recovery log.'
    }
    Log ('SUCCESS: HTTP/2 Cloudflare connector is running as PID ' + $p.Id)
} else {
    Log ('SUCCESS: Cloudflare connector is running as PID ' + $p.Id)
}

# 7. Leave a durable status marker for later remote inspection.
$marker = Join-Path $root 'MGS_BRIDGE_READY.txt'
@(
    'MGS Cloudflare recovery connector is running.',
    ('Started: ' + (Get-Date -Format o)),
    ('PID: ' + $p.Id),
    ('Tunnel: ' + $tunnelId),
    'Origin: http://127.0.0.1:8765',
    'Public hostname: mcp.matthewgsteel.com',
    ('Recovery log: ' + $log)
) | Set-Content -LiteralPath $marker -Encoding ASCII

Write-Host ''
Write-Host 'SUCCESS: THE MGS CLOUDFLARE RECOVERY CONNECTOR IS RUNNING.' -ForegroundColor Green
Write-Host 'You may leave this PowerShell window alone. ChatGPT can now retest the private connector.' -ForegroundColor Green
Write-Host ('Recovery log: ' + $log) -ForegroundColor DarkGray
