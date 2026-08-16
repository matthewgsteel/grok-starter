$ErrorActionPreference = 'Stop'

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$root = if (Test-Path 'D:\') { 'D:\MGS_RECOVERY' } else { Join-Path $env:TEMP 'MGS_RECOVERY' }
New-Item -ItemType Directory -Force -Path $root | Out-Null
$log = Join-Path $root ("MGS_cloudflare_originfix_$stamp.log")

function Log([string]$m) {
    $line = "[$(Get-Date -Format o)] $m"
    $line | Tee-Object -FilePath $log -Append
}

function Test-Origin([string]$baseUrl) {
    $savedCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    try {
        foreach ($path in @('/mcp','/')) {
            foreach ($method in @('GET','POST')) {
                $url = $baseUrl.TrimEnd('/') + $path
                try {
                    $req = [System.Net.HttpWebRequest]::Create($url)
                    $req.Method = $method
                    $req.Timeout = 3500
                    $req.ReadWriteTimeout = 3500
                    $req.AllowAutoRedirect = $false
                    $req.UserAgent = 'MGS-Recovery-Origin-Probe/1.0'
                    if ($method -eq 'POST') {
                        $bytes = [Text.Encoding]::UTF8.GetBytes('{}')
                        $req.ContentType = 'application/json'
                        $req.ContentLength = $bytes.Length
                        $stream = $req.GetRequestStream()
                        $stream.Write($bytes,0,$bytes.Length)
                        $stream.Close()
                    }
                    $resp = $req.GetResponse()
                    $code = [int]$resp.StatusCode
                    $resp.Close()
                    return [pscustomobject]@{ Ok=$true; Base=$baseUrl; Url=$url; Method=$method; Code=$code }
                } catch [System.Net.WebException] {
                    if ($_.Exception.Response) {
                        try {
                            $code = [int]$_.Exception.Response.StatusCode
                            $_.Exception.Response.Close()
                            return [pscustomobject]@{ Ok=$true; Base=$baseUrl; Url=$url; Method=$method; Code=$code }
                        } catch {}
                    }
                } catch {}
            }
        }
    } finally {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $savedCallback
    }
    return [pscustomobject]@{ Ok=$false; Base=$baseUrl; Url=$null; Method=$null; Code=$null }
}

function Get-CloudflaredExe {
    $candidates = @(
        'C:\Program Files (x86)\cloudflared\cloudflared.exe',
        'C:\Cloudflared\bin\cloudflared.exe',
        (Join-Path $root 'cloudflared.exe'),
        'C:\Windows.old\Program Files (x86)\cloudflared\cloudflared.exe'
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) {
            try {
                $v = & $c --version 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Log ('Using cloudflared: ' + $c + ' | ' + ($v -join ' '))
                    return $c
                }
            } catch {}
        }
    }
    $dest = Join-Path $root 'cloudflared.exe'
    Log 'No runnable cloudflared binary found. Downloading the current official Windows AMD64 binary.'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe' -OutFile $dest
    $v = & $dest --version 2>&1
    Log ('Downloaded cloudflared: ' + ($v -join ' '))
    return $dest
}

Log 'MGS Cloudflare origin-aware recovery started. No reboot, no DISM/SFC, no Proton changes, no user-data cleanup.'

# 1. Prove the local MCP listener and discover the address it is actually bound to.
$listeners = @(Get-NetTCPConnection -LocalPort 8765 -State Listen -ErrorAction SilentlyContinue)
if (-not $listeners) {
    Log 'No listener on 8765. Running the existing local MGS MCP restart helper once.'
    $restart = 'C:\ProgramData\MGS-MCP\restart-mgs-mcp.ps1'
    if (Test-Path $restart) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $restart
    } else {
        $task = Get-ScheduledTask -TaskName 'MGS MCP Server' -ErrorAction SilentlyContinue
        if ($task) { Start-ScheduledTask -TaskName 'MGS MCP Server' }
    }
    Start-Sleep -Seconds 5
    $listeners = @(Get-NetTCPConnection -LocalPort 8765 -State Listen -ErrorAction SilentlyContinue)
}
if (-not $listeners) {
    Log 'FAIL: nothing is listening on port 8765.'
    throw 'MGS MCP is not listening on port 8765.'
}

foreach ($l in $listeners) {
    Log ("8765 LISTENER address=$($l.LocalAddress) pid=$($l.OwningProcess)")
}

# 2. Probe every plausible local origin over HTTP and HTTPS. Any HTTP response code proves transport works.
$bases = New-Object System.Collections.Generic.List[string]
$bases.Add('http://127.0.0.1:8765')
$bases.Add('http://localhost:8765')
$bases.Add('http://[::1]:8765')
$bases.Add('https://127.0.0.1:8765')
$bases.Add('https://localhost:8765')
$bases.Add('https://[::1]:8765')

foreach ($l in $listeners) {
    $a = [string]$l.LocalAddress
    if ($a -and $a -ne '0.0.0.0' -and $a -ne '::' -and $a -ne '::1' -and $a -ne '127.0.0.1') {
        if ($a -match ':') {
            $bases.Add("http://[$a]:8765")
            $bases.Add("https://[$a]:8765")
        } else {
            $bases.Add("http://$a`:8765")
            $bases.Add("https://$a`:8765")
        }
    }
}

$origin = $null
foreach ($b in ($bases | Select-Object -Unique)) {
    $r = Test-Origin $b
    if ($r.Ok) {
        Log ("ORIGIN WORKS: $($r.Base) via $($r.Method) $($r.Url) -> HTTP $($r.Code)")
        $origin = $r.Base
        break
    } else {
        Log ("Origin probe failed: $b")
    }
}

# If the socket exists but no HTTP/S candidate responds, restart just the MCP origin once and reprobe.
if (-not $origin) {
    Log 'Port 8765 exists but no HTTP/S candidate responded. Restarting only the local MGS MCP origin once.'
    $restart = 'C:\ProgramData\MGS-MCP\restart-mgs-mcp.ps1'
    if (Test-Path $restart) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $restart
    } else {
        $task = Get-ScheduledTask -TaskName 'MGS MCP Server' -ErrorAction SilentlyContinue
        if ($task) { Start-ScheduledTask -TaskName 'MGS MCP Server' }
    }
    Start-Sleep -Seconds 5
    foreach ($b in ($bases | Select-Object -Unique)) {
        $r = Test-Origin $b
        if ($r.Ok) {
            Log ("ORIGIN WORKS AFTER MCP RESTART: $($r.Base) via $($r.Method) $($r.Url) -> HTTP $($r.Code)")
            $origin = $r.Base
            break
        }
    }
}

if (-not $origin) {
    Log 'FAIL: port 8765 is listening but the MCP is not speaking reachable HTTP or HTTPS on the tested local addresses.'
    $err = 'C:\ProgramData\MGS-MCP\server.error.log'
    if (Test-Path $err) {
        Log 'Recent MGS MCP error log follows:'
        Get-Content $err -Tail 60 -ErrorAction SilentlyContinue | ForEach-Object { Log $_ }
    }
    throw 'Local MCP socket exists, but no reachable HTTP/S origin was found.'
}

# 3. Recover the tunnel UUID and credential file from the isolated v4 config or the surviving systemprofile config.
$cfgCandidates = @(
    (Join-Path $root 'mgs-recovery-config.yml'),
    'C:\Windows\System32\config\systemprofile\.cloudflared\config.yml',
    'C:\Windows.old\Windows\System32\config\systemprofile\.cloudflared\config.yml'
) | Where-Object { Test-Path $_ }

$tunnelId = $null
$cred = $null
$sourceCfg = $null
foreach ($c in $cfgCandidates) {
    $text = Get-Content -LiteralPath $c -Raw -ErrorAction SilentlyContinue
    if (-not $text) { continue }
    $id = $null
    if ($text -match '(?im)^\s*tunnel\s*:\s*["'']?([0-9a-fA-F-]{36})') { $id = $matches[1] }
    if (-not $id) { continue }
    $credPath = $null
    if ($text -match '(?im)^\s*credentials-file\s*:\s*["'']?([^\r\n"'']+)') {
        $credPath = [Environment]::ExpandEnvironmentVariables($matches[1].Trim())
        if (-not [IO.Path]::IsPathRooted($credPath)) { $credPath = Join-Path (Split-Path $c -Parent) $credPath }
    }
    if ($credPath -and (Test-Path $credPath)) {
        $tunnelId = $id
        $cred = $credPath
        $sourceCfg = $c
        break
    }
    $nearby = Join-Path (Split-Path $c -Parent) ($id + '.json')
    if (Test-Path $nearby) {
        $tunnelId = $id
        $cred = $nearby
        $sourceCfg = $c
        break
    }
}
if (-not $tunnelId -or -not $cred) {
    Log 'FAIL: could not recover the tunnel UUID and credential JSON.'
    throw 'Tunnel credentials unavailable.'
}
Log ("Tunnel recovered: $tunnelId from $sourceCfg. Credential secret is not logged.")

$credCopy = Join-Path $root ($tunnelId + '.json')
Copy-Item -LiteralPath $cred -Destination $credCopy -Force

# 4. Rewrite only the isolated recovery config to the origin that actually answered locally.
$recoveryCfg = Join-Path $root 'mgs-recovery-config.yml'
$credYaml = $credCopy -replace '\\','/'
@(
    "tunnel: $tunnelId",
    "credentials-file: $credYaml",
    'ingress:',
    '  - hostname: mcp.matthewgsteel.com',
    "    service: $origin",
    '  - service: http_status:404'
) | Set-Content -LiteralPath $recoveryCfg -Encoding ASCII
Log ("Recovery ingress normalized: mcp.matthewgsteel.com -> $origin")

$exe = Get-CloudflaredExe
$validate = & $exe --config=$recoveryCfg tunnel ingress validate 2>&1
Log ('Ingress validation: ' + ($validate -join ' '))
if ($LASTEXITCODE -ne 0) { throw 'Recovery ingress validation failed.' }

# 5. Stop only prior isolated recovery connectors. Also gracefully stop the legacy service if it uses the fragile systemprofile config.
$procs = @(Get-CimInstance Win32_Process -Filter "Name='cloudflared.exe'" -ErrorAction SilentlyContinue)
foreach ($p in $procs) {
    $cmd = [string]$p.CommandLine
    if ($cmd -like '*MGS_RECOVERY*mgs-recovery-config.yml*') {
        Log ("Stopping prior isolated recovery connector PID $($p.ProcessId)")
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

$legacySvcs = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { [string]$_.PathName -like '*systemprofile\.cloudflared\config.yml*' })
foreach ($s in $legacySvcs) {
    if ($s.State -eq 'Running') {
        Log ("Gracefully stopping legacy Cloudflare service $($s.Name) so it cannot compete with the isolated connector.")
        Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue
    }
}
Start-Sleep -Seconds 2

# 6. Launch the isolated connector and force one public request so cloudflared logs any origin error immediately.
$outLog = Join-Path $root ("MGS_cloudflared_originfix_stdout_$stamp.txt")
$errLog = Join-Path $root ("MGS_cloudflared_originfix_stderr_$stamp.txt")
$p = Start-Process -FilePath $exe -ArgumentList @("--config=$recoveryCfg",'--loglevel=debug','tunnel','run') -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 9
if ($p.HasExited) {
    Log ("FAIL: isolated cloudflared exited with code $($p.ExitCode)")
    Get-Content $errLog -Tail 100 -ErrorAction SilentlyContinue | ForEach-Object { Log $_ }
    throw 'Isolated cloudflared connector exited.'
}
Log ("Isolated Cloudflare connector is running as PID $($p.Id)")

function Test-PublicMcp {
    try {
        $req = [System.Net.HttpWebRequest]::Create('https://mcp.matthewgsteel.com/mcp')
        $req.Method = 'GET'
        $req.Timeout = 6000
        $req.AllowAutoRedirect = $false
        $req.UserAgent = 'MGS-Recovery-Public-Probe/1.0'
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        $resp.Close()
        return $code
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) {
            $code = [int]$_.Exception.Response.StatusCode
            $_.Exception.Response.Close()
            return $code
        }
        return 0
    } catch { return 0 }
}

$publicCode = Test-PublicMcp
Log ("Public MCP probe returned HTTP $publicCode")

# 7. If the tunnel is healthy locally but public traffic is still 502, normalize the DNS route if an account cert survived.
if ($publicCode -eq 502 -or $publicCode -eq 0) {
    Start-Sleep -Seconds 2
    Log 'Public route is still not healthy. Cloudflared stderr tail follows before any DNS action:'
    Get-Content $errLog -Tail 80 -ErrorAction SilentlyContinue | ForEach-Object { Log $_ }

    $certs = @(
        'C:\Windows\System32\config\systemprofile\.cloudflared\cert.pem',
        'C:\Windows.old\Windows\System32\config\systemprofile\.cloudflared\cert.pem',
        'C:\Users\mgste\.cloudflared\cert.pem',
        'C:\Windows.old\Users\mgste\.cloudflared\cert.pem'
    ) | Where-Object { Test-Path $_ }

    if ($certs) {
        $env:TUNNEL_ORIGIN_CERT = $certs[0]
        Log ('A surviving Cloudflare account certificate exists at ' + $certs[0] + '. Normalizing the DNS route to the recovered tunnel UUID.')
        $route = & $exe tunnel route dns --overwrite-dns $tunnelId 'mcp.matthewgsteel.com' 2>&1
        Log ('DNS route result: ' + ($route -join ' '))
        Start-Sleep -Seconds 8
        $publicCode = Test-PublicMcp
        Log ("Public MCP probe after DNS normalization returned HTTP $publicCode")
    } else {
        Log 'No cert.pem survived, so the script did not attempt a Cloudflare-side DNS rewrite.'
    }
}

# Any status other than 0/502/504 proves the request reached an HTTP service rather than a dead origin.
if ($publicCode -ne 0 -and $publicCode -ne 502 -and $publicCode -ne 504) {
    $marker = Join-Path $root 'MGS_BRIDGE_READY.txt'
    @(
        'MGS public bridge recovered.',
        ('Recovered: ' + (Get-Date -Format o)),
        ('Tunnel PID: ' + $p.Id),
        ('Tunnel UUID: ' + $tunnelId),
        ('Local origin: ' + $origin),
        ('Public probe HTTP status: ' + $publicCode),
        ('Recovery log: ' + $log)
    ) | Set-Content -LiteralPath $marker -Encoding ASCII
    Write-Host ''
    Write-Host 'SUCCESS: PUBLIC MGS BRIDGE IS REACHING AN HTTP ORIGIN AGAIN.' -ForegroundColor Green
    Write-Host ('Public probe HTTP status: ' + $publicCode) -ForegroundColor Green
    Write-Host 'Tell ChatGPT: TEST NOW. Leave the PowerShell window alone.' -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host ('NOT YET RECOVERED: public probe HTTP ' + $publicCode) -ForegroundColor Red
    Write-Host 'The exact local-origin and cloudflared diagnostics were preserved automatically.' -ForegroundColor Yellow
    Write-Host ('Recovery log: ' + $log) -ForegroundColor Yellow
    Write-Host 'You do not need to copy the whole screen. Tell ChatGPT only: v5 finished.' -ForegroundColor Yellow
}
