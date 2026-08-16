$ErrorActionPreference = 'Stop'

$root = 'D:\MGS_RECOVERY'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$log = Join-Path $root ("MGS_EMERGENCY_ACCESS_$stamp.log")
Start-Transcript -Path $log -Force | Out-Null

try {
    Write-Host 'MGS EMERGENCY ACCESS' -ForegroundColor Cyan
    Write-Host 'Bridge only. No reboot. No DISM/SFC. No Proton changes. No Windows cleanup. No user-data changes.' -ForegroundColor DarkGray

    $tunnelId = 'fdede1c4-f1eb-436a-a331-c5202e0cff12'
    $hostName = 'mcp.matthewgsteel.com'
    $origin = 'http://127.0.0.1:8765'

    # Prove the local MCP origin before touching Cloudflare.
    $listener = Get-NetTCPConnection -LocalPort 8765 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $listener) { throw 'Local MGS MCP is not listening on port 8765.' }
    Write-Host ('LOCAL MCP LISTENER: 127.0.0.1:8765 PID ' + $listener.OwningProcess) -ForegroundColor Green

    $headers = @{ Accept='application/json, text/event-stream'; 'MCP-Protocol-Version'='2025-06-18' }
    $localCode = 0
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Uri ($origin + '/mcp') -Method Get -Headers $headers -TimeoutSec 5
        $localCode = [int]$r.StatusCode
    } catch {
        if ($_.Exception.Response) { $localCode = [int]$_.Exception.Response.StatusCode }
    }
    if ($localCode -eq 0) { throw 'Local MCP socket exists but HTTP is not responding.' }
    Write-Host ('LOCAL MCP HTTP: ' + $localCode) -ForegroundColor Green

    # Recover the tunnel credential. Prefer the preserved D: copy.
    $cred = @(
        (Join-Path $root ($tunnelId + '.json')),
        ('C:\Windows\System32\config\systemprofile\.cloudflared\' + $tunnelId + '.json'),
        ('C:\Windows.old\Windows\System32\config\systemprofile\.cloudflared\' + $tunnelId + '.json'),
        ('C:\Users\mgste\.cloudflared\' + $tunnelId + '.json'),
        ('C:\Windows.old\Users\mgste\.cloudflared\' + $tunnelId + '.json')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $cred) { throw 'Cloudflare tunnel credential JSON was not found.' }
    $cred = (Resolve-Path $cred).Path
    Write-Host ('TUNNEL CREDENTIAL FOUND: ' + [IO.Path]::GetFileName($cred)) -ForegroundColor Green

    # Use the installed binary if it executes; otherwise use a fresh official binary on D:.
    $installed = 'C:\Program Files (x86)\cloudflared\cloudflared.exe'
    $cf = $null
    if (Test-Path $installed) {
        try {
            $version = & $installed --version 2>&1
            if ($LASTEXITCODE -eq 0) { $cf = $installed; Write-Host ('CLOUDFLARED: ' + ($version -join ' ')) -ForegroundColor Green }
        } catch {}
    }
    if (-not $cf) {
        $cf = Join-Path $root 'cloudflared-current.exe'
        Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe' -OutFile $cf
        $version = & $cf --version 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'Fresh cloudflared binary would not execute.' }
        Write-Host ('FRESH CLOUDFLARED: ' + ($version -join ' ')) -ForegroundColor Green
    }

    # Minimal isolated locally-managed tunnel config.
    $cfg = Join-Path $root 'mgs-emergency-access.yml'
    $credYaml = $cred -replace '\\','/'
    @(
        "tunnel: $tunnelId",
        "credentials-file: $credYaml",
        'ingress:',
        "  - hostname: $hostName",
        "    service: $origin",
        '  - service: http_status:404'
    ) | Set-Content -LiteralPath $cfg -Encoding ASCII

    # Use Cloudflare's documented Windows/local-tunnel syntax.
    & $cf "--config=$cfg" tunnel ingress validate
    if ($LASTEXITCODE -ne 0) { throw 'Ingress validation failed.' }
    & $cf "--config=$cfg" tunnel ingress rule ('https://' + $hostName + '/mcp')
    Write-Host 'INGRESS CONFIG VALIDATED.' -ForegroundColor Green

    # Stop the legacy MGS service only. Leave Dominican and unrelated tunnels alone.
    $mgsSvc = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        $_.DisplayName -eq 'Cloudflared MGS MCP Tunnel' -or $_.Name -eq 'Cloudflared MGS MCP Tunnel'
    } | Select-Object -First 1
    if ($mgsSvc) {
        if ($mgsSvc.State -eq 'Running') {
            Stop-Service -Name $mgsSvc.Name -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
        if ($mgsSvc.ProcessId -and $mgsSvc.ProcessId -ne 0) {
            Stop-Process -Id $mgsSvc.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }

    # Stop prior MGS recovery replicas, including earlier emergency binaries.
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'cloudflared*.exe' } | ForEach-Object {
        $cmd = [string]$_.CommandLine
        if ($cmd -like ('*' + $tunnelId + '*') -or $cmd -like '*mgs-recovery-config*' -or $cmd -like '*mgs-emergency-access.yml*') {
            Write-Host ('STOPPING OLD MGS REPLICA PID ' + $_.ProcessId) -ForegroundColor Yellow
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Seconds 2

    # If the Cloudflare account certificate survived, clear stale connector records and verify DNS routing.
    $cert = @(
        'C:\Windows\System32\config\systemprofile\.cloudflared\cert.pem',
        'C:\Windows.old\Windows\System32\config\systemprofile\.cloudflared\cert.pem',
        'C:\Users\mgste\.cloudflared\cert.pem',
        'C:\Windows.old\Users\mgste\.cloudflared\cert.pem'
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($cert) {
        $env:TUNNEL_ORIGIN_CERT = $cert
        Write-Host 'CLEANING STALE CONNECTOR RECORDS FOR THIS TUNNEL...' -ForegroundColor Cyan
        & $cf tunnel cleanup $tunnelId 2>&1 | ForEach-Object { Write-Host $_ }

        $expected = $tunnelId + '.cfargotunnel.com'
        $dns = Resolve-DnsName $hostName -Type CNAME -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($dns -and $dns.NameHost) {
            $actual = $dns.NameHost.TrimEnd('.')
            Write-Host ('DNS CNAME: ' + $actual)
            if ($actual -ne $expected) {
                Write-Host ('DNS DOES NOT POINT TO THIS TUNNEL. Attempting Cloudflare route normalization to ' + $expected) -ForegroundColor Yellow
                $help = (& $cf tunnel route dns --help 2>&1) -join "`n"
                if ($help -match '--overwrite-dns') {
                    & $cf tunnel route dns --overwrite-dns $tunnelId $hostName
                } else {
                    & $cf tunnel route dns $tunnelId $hostName
                }
            }
        }
    }

    # Launch exactly one clean connector. Config flag is intentionally before 'tunnel run'.
    $stdout = Join-Path $root ("MGS_cloudflared_emergency_stdout_$stamp.txt")
    $stderr = Join-Path $root ("MGS_cloudflared_emergency_stderr_$stamp.txt")
    $args = @("--config=$cfg", 'tunnel', '--loglevel', 'debug', 'run', $tunnelId)
    $p = Start-Process -FilePath $cf -ArgumentList $args -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 15

    if ($p.HasExited) {
        Write-Host ('CLOUDFLARED EXITED WITH CODE ' + $p.ExitCode) -ForegroundColor Red
        Get-Content $stderr -Tail 120 -ErrorAction SilentlyContinue
        throw 'Emergency Cloudflare connector did not stay running.'
    }
    Write-Host ('CLEAN MGS CONNECTOR RUNNING PID ' + $p.Id) -ForegroundColor Green

    # Test the exact public MCP route from the PC.
    $publicCode = 0
    try {
        $pub = Invoke-WebRequest -UseBasicParsing -Uri ('https://' + $hostName + '/mcp') -Method Get -Headers $headers -TimeoutSec 10
        $publicCode = [int]$pub.StatusCode
    } catch {
        if ($_.Exception.Response) { $publicCode = [int]$_.Exception.Response.StatusCode }
    }
    Write-Host ('PUBLIC MCP HTTP: ' + $publicCode)

    if ($publicCode -eq 0 -or $publicCode -eq 502 -or $publicCode -eq 504) {
        Write-Host 'PUBLIC BRIDGE IS STILL NOT HEALTHY. Exact tunnel error tail:' -ForegroundColor Red
        Get-Content $stderr -Tail 120 -ErrorAction SilentlyContinue
        Write-Host ('FULL TRANSCRIPT: ' + $log) -ForegroundColor Yellow
    } else {
        @(
            'MGS emergency bridge is live.',
            ('Time: ' + (Get-Date -Format o)),
            ('Tunnel: ' + $tunnelId),
            ('PID: ' + $p.Id),
            ('Origin: ' + $origin),
            ('Public HTTP status: ' + $publicCode),
            ('Transcript: ' + $log)
        ) | Set-Content -LiteralPath (Join-Path $root 'MGS_BRIDGE_READY.txt') -Encoding ASCII
        Write-Host ''
        Write-Host 'SUCCESS: MGS PUBLIC BRIDGE IS LIVE.' -ForegroundColor Green
        Write-Host 'LEAVE THE PROCESS ALONE. CHATGPT CAN TAKE OVER.' -ForegroundColor Green
    }
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
}
