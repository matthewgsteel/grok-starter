$ErrorActionPreference = 'Stop'

$root = 'D:\MGS_RECOVERY'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$log = Join-Path $root ("MGS_EMERGENCY_ACCESS_$stamp.log")

Start-Transcript -Path $log -Force | Out-Null
try {
    Write-Host 'MGS EMERGENCY ACCESS' -ForegroundColor Cyan
    Write-Host 'No reboot. No DISM/SFC. No Proton changes. No Windows cleanup. No user-data deletion.' -ForegroundColor DarkGray

    $tunnelId = 'fdede1c4-f1eb-436a-a331-c5202e0cff12'
    $hostName = 'mcp.matthewgsteel.com'
    $origin = 'http://127.0.0.1:8765'

    # 1. Prove local MCP is actually alive.
    $headers = @{ Accept='application/json, text/event-stream'; 'MCP-Protocol-Version'='2025-06-18' }
    try {
        $local = Invoke-WebRequest -UseBasicParsing -Uri "$origin/mcp" -Method Get -Headers $headers -TimeoutSec 5
        Write-Host ("LOCAL MCP: HTTP " + [int]$local.StatusCode) -ForegroundColor Green
    } catch {
        if ($_.Exception.Response) {
            $code = [int]$_.Exception.Response.StatusCode
            Write-Host ("LOCAL MCP: HTTP $code") -ForegroundColor Yellow
        } else {
            throw 'Local MCP on 127.0.0.1:8765 is not reachable.'
        }
    }

    # 2. Find the tunnel credential file. Prefer the already recovered D: copy.
    $credCandidates = @(
        (Join-Path $root ($tunnelId + '.json')),
        ('C:\Windows\System32\config\systemprofile\.cloudflared\' + $tunnelId + '.json'),
        ('C:\Windows.old\Windows\System32\config\systemprofile\.cloudflared\' + $tunnelId + '.json'),
        ('C:\Users\mgste\.cloudflared\' + $tunnelId + '.json'),
        ('C:\Windows.old\Users\mgste\.cloudflared\' + $tunnelId + '.json')
    )
    $cred = $credCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $cred) { throw 'Recovered Cloudflare tunnel credential JSON was not found.' }
    Write-Host ('TUNNEL CREDENTIAL: ' + $cred) -ForegroundColor Green

    # 3. Use a fresh official cloudflared binary from D: so the damaged Windows install is not trusted.
    $cf = Join-Path $root 'cloudflared-current.exe'
    $download = $true
    if (Test-Path $cf) {
        try {
            $v = & $cf --version 2>&1
            if ($LASTEXITCODE -eq 0) { $download = $false; Write-Host ('CLOUDFLARED: ' + ($v -join ' ')) -ForegroundColor Green }
        } catch {}
    }
    if ($download) {
        Write-Host 'Downloading current official cloudflared to D: recovery folder...' -ForegroundColor Cyan
        Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe' -OutFile $cf
        $v = & $cf --version 2>&1
        Write-Host ('CLOUDFLARED: ' + ($v -join ' ')) -ForegroundColor Green
    }

    # 4. Build a minimal isolated config with the exact proven origin.
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

    & $cf tunnel --config $cfg ingress validate
    if ($LASTEXITCODE -ne 0) { throw 'Cloudflare ingress validation failed.' }
    & $cf tunnel --config $cfg ingress rule ("https://" + $hostName + '/mcp')

    # 5. Stop only MGS tunnel replicas. Do not touch Dominican or unrelated cloudflared processes.
    Get-CimInstance Win32_Process -Filter "Name='cloudflared.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
        $cmd = [string]$_.CommandLine
        if ($cmd -like '*MGS_RECOVERY*' -or $cmd -like ('*' + $tunnelId + '*') -or $cmd -like '*mgs-emergency-access.yml*') {
            Write-Host ("Stopping old MGS tunnel replica PID " + $_.ProcessId) -ForegroundColor Yellow
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }

    $mgsSvc = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        $_.DisplayName -eq 'Cloudflared MGS MCP Tunnel' -or $_.Name -eq 'Cloudflared MGS MCP Tunnel'
    } | Select-Object -First 1
    if ($mgsSvc -and $mgsSvc.State -eq 'Running') {
        Write-Host ('Stopping legacy MGS tunnel service: ' + $mgsSvc.Name) -ForegroundColor Yellow
        Stop-Service -Name $mgsSvc.Name -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2

    # 6. If an account cert survived, ensure the public hostname points to this exact tunnel.
    $cert = @(
        'C:\Windows\System32\config\systemprofile\.cloudflared\cert.pem',
        'C:\Windows.old\Windows\System32\config\systemprofile\.cloudflared\cert.pem',
        'C:\Users\mgste\.cloudflared\cert.pem',
        'C:\Windows.old\Users\mgste\.cloudflared\cert.pem'
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($cert) {
        $env:TUNNEL_ORIGIN_CERT = $cert
        $dns = Resolve-DnsName $hostName -Type CNAME -ErrorAction SilentlyContinue | Select-Object -First 1
        $expected = $tunnelId + '.cfargotunnel.com'
        if ($dns -and $dns.NameHost) { Write-Host ('CURRENT DNS CNAME: ' + $dns.NameHost) }
        if (-not $dns -or $dns.NameHost.TrimEnd('.') -ne $expected) {
            Write-Host ('Normalizing Cloudflare DNS route to ' + $expected) -ForegroundColor Cyan
            $help = (& $cf tunnel route dns --help 2>&1) -join "`n"
            if ($help -match '--overwrite-dns') {
                & $cf tunnel route dns --overwrite-dns $tunnelId $hostName
            } else {
                & $cf tunnel route dns $tunnelId $hostName
            }
        }
    } else {
        Write-Host 'No cert.pem found. Skipping DNS mutation; existing DNS route will be used.' -ForegroundColor Yellow
    }

    # 7. Launch one clean named-tunnel replica using only the isolated D: config.
    $stdout = Join-Path $root ("MGS_cloudflared_emergency_stdout_$stamp.txt")
    $stderr = Join-Path $root ("MGS_cloudflared_emergency_stderr_$stamp.txt")
    $args = @('tunnel','--config',$cfg,'run',$tunnelId)
    $p = Start-Process -FilePath $cf -ArgumentList $args -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 12

    if ($p.HasExited) {
        Write-Host ('CLOUDFLARED EXITED: ' + $p.ExitCode) -ForegroundColor Red
        Get-Content $stderr -Tail 120 -ErrorAction SilentlyContinue
        throw 'The emergency Cloudflare replica did not stay running.'
    }
    Write-Host ('CLOUDFLARED RUNNING PID ' + $p.Id) -ForegroundColor Green

    # 8. Verify the public hostname from the same machine. Any non-502/504 HTTP response proves the route reaches the MCP.
    $publicCode = 0
    try {
        $pub = Invoke-WebRequest -UseBasicParsing -Uri ('https://' + $hostName + '/mcp') -Method Get -Headers $headers -TimeoutSec 8
        $publicCode = [int]$pub.StatusCode
    } catch {
        if ($_.Exception.Response) { $publicCode = [int]$_.Exception.Response.StatusCode }
    }
    Write-Host ('PUBLIC MCP: HTTP ' + $publicCode)

    if ($publicCode -eq 0 -or $publicCode -eq 502 -or $publicCode -eq 504) {
        Write-Host 'PUBLIC BRIDGE NOT YET HEALTHY. Exact cloudflared stderr follows:' -ForegroundColor Red
        Get-Content $stderr -Tail 120 -ErrorAction SilentlyContinue
        Write-Host ('Full log: ' + $log) -ForegroundColor Yellow
        exit 2
    }

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
    Write-Host 'Leave this process alone. ChatGPT can take over now.' -ForegroundColor Green
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
}
