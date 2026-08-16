$ErrorActionPreference = 'Stop'

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$root = if (Test-Path 'D:\') { 'D:\MGS_RECOVERY' } else { Join-Path $env:TEMP 'MGS_RECOVERY' }
New-Item -ItemType Directory -Force -Path $root | Out-Null
$log = Join-Path $root ("MGS_cloudflare_originfix_v6_$stamp.log")

function Log([string]$m) {
    $line = "[$(Get-Date -Format o)] $m"
    Add-Content -LiteralPath $log -Value $line
    Write-Host $line
}

function Http-Probe([string]$url,[string]$method='GET',[string]$body='') {
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Method = $method
        $req.Timeout = 5000
        $req.ReadWriteTimeout = 5000
        $req.AllowAutoRedirect = $false
        $req.UserAgent = 'MGS-Recovery-Probe/1.0'
        $req.Accept = 'application/json, text/event-stream'
        $req.Headers.Add('MCP-Protocol-Version','2025-06-18')
        if ($method -eq 'POST') {
            $bytes = [Text.Encoding]::UTF8.GetBytes($body)
            $req.ContentType = 'application/json'
            $req.ContentLength = $bytes.Length
            $stream = $req.GetRequestStream()
            $stream.Write($bytes,0,$bytes.Length)
            $stream.Close()
        }
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        $resp.Close()
        return $code
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) {
            try {
                $code = [int]$_.Exception.Response.StatusCode
                $_.Exception.Response.Close()
                return $code
            } catch {}
        }
        return 0
    } catch { return 0 }
}

function Get-CloudflaredExe {
    foreach ($c in @(
        'C:\Program Files (x86)\cloudflared\cloudflared.exe',
        'C:\Cloudflared\bin\cloudflared.exe',
        (Join-Path $root 'cloudflared.exe'),
        'C:\Windows.old\Program Files (x86)\cloudflared\cloudflared.exe'
    )) {
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
    Log 'Downloading current official cloudflared Windows AMD64 binary.'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe' -OutFile $dest
    return $dest
}

Log 'MGS v6 recovery started. No reboot, no DISM/SFC, no Proton changes, no Windows cleanup.'

$localGet = Http-Probe 'http://127.0.0.1:8765/mcp' 'GET'
$initBody = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"mgs-recovery-probe","version":"1.0"}}}'
$localPost = Http-Probe 'http://127.0.0.1:8765/mcp' 'POST' $initBody
Log ("Local MCP GET status=$localGet POST initialize status=$localPost")
if ($localGet -eq 0 -and $localPost -eq 0) {
    throw 'Local MCP transport is not responding on 127.0.0.1:8765.'
}

$cfgCandidates = @(
    (Join-Path $root 'mgs-recovery-config.yml'),
    'C:\Windows\System32\config\systemprofile\.cloudflared\config.yml',
    'C:\Windows.old\Windows\System32\config\systemprofile\.cloudflared\config.yml'
) | Where-Object { Test-Path $_ }

$tunnelId = $null
$cred = $null
foreach ($c in $cfgCandidates) {
    $text = Get-Content -LiteralPath $c -Raw -ErrorAction SilentlyContinue
    if (-not $text) { continue }
    if ($text -match '(?im)^\s*tunnel\s*:\s*["'']?([0-9a-fA-F-]{36})') {
        $id = $matches[1]
        $cp = $null
        if ($text -match '(?im)^\s*credentials-file\s*:\s*["'']?([^\r\n"'']+)') {
            $cp = [Environment]::ExpandEnvironmentVariables($matches[1].Trim())
            if (-not [IO.Path]::IsPathRooted($cp)) { $cp = Join-Path (Split-Path $c -Parent) $cp }
        }
        if ($cp -and (Test-Path $cp)) {
            $tunnelId = $id
            $cred = (Resolve-Path $cp).Path
            break
        }
        $nearby = Join-Path (Split-Path $c -Parent) ($id + '.json')
        if (Test-Path $nearby) {
            $tunnelId = $id
            $cred = (Resolve-Path $nearby).Path
            break
        }
    }
}
if (-not $tunnelId -or -not $cred) { throw 'Could not recover tunnel UUID and credential JSON.' }
Log ("Recovered tunnel $tunnelId using credential file $([IO.Path]::GetFileName($cred)); secret content is not logged.")

$recoveryCfg = Join-Path $root 'mgs-recovery-config-v6.yml'
$credYaml = $cred -replace '\\','/'
@(
    "tunnel: $tunnelId",
    "credentials-file: $credYaml",
    'ingress:',
    '  - hostname: mcp.matthewgsteel.com',
    '    service: http://127.0.0.1:8765',
    '  - service: http_status:404'
) | Set-Content -LiteralPath $recoveryCfg -Encoding ASCII

$exe = Get-CloudflaredExe
$validate = & $exe --config=$recoveryCfg tunnel ingress validate 2>&1
Log ('Ingress validation: ' + ($validate -join ' '))
if ($LASTEXITCODE -ne 0) { throw 'Ingress validation failed.' }
$rule = & $exe --config=$recoveryCfg tunnel ingress rule 'https://mcp.matthewgsteel.com/mcp' 2>&1
Log ('Ingress rule match: ' + ($rule -join ' '))

$procs = @(Get-CimInstance Win32_Process -Filter "Name='cloudflared.exe'" -ErrorAction SilentlyContinue)
foreach ($p in $procs) {
    $cmd = [string]$p.CommandLine
    if ($cmd -like '*MGS_RECOVERY*' -or $cmd -like "*$tunnelId*") {
        Log ("Stopping prior MGS recovery connector PID $($p.ProcessId)")
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
}
$svc = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'Cloudflared MGS MCP Tunnel' -or $_.Name -eq 'Cloudflared MGS MCP Tunnel' } | Select-Object -First 1
if ($svc -and $svc.State -eq 'Running') {
    Log ('Stopping legacy MGS Cloudflare service ' + $svc.Name)
    Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 2

$outLog = Join-Path $root ("MGS_cloudflared_v6_stdout_$stamp.txt")
$errLog = Join-Path $root ("MGS_cloudflared_v6_stderr_$stamp.txt")
$p = Start-Process -FilePath $exe -ArgumentList @("--config=$recoveryCfg",'--loglevel=debug','tunnel','run') -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 10
if ($p.HasExited) {
    Log ("cloudflared exited code $($p.ExitCode)")
    Get-Content $errLog -Tail 100 -ErrorAction SilentlyContinue | ForEach-Object { Log $_ }
    throw 'cloudflared did not stay running.'
}
Log ("Fresh MGS cloudflared connector running PID $($p.Id)")

$publicGet = Http-Probe 'https://mcp.matthewgsteel.com/mcp' 'GET'
$publicPost = Http-Probe 'https://mcp.matthewgsteel.com/mcp' 'POST' $initBody
Log ("Public MCP GET status=$publicGet POST initialize status=$publicPost")

try {
    $dns = Resolve-DnsName 'mcp.matthewgsteel.com' -Type CNAME -ErrorAction Stop | Select-Object -First 1
    if ($dns) { Log ('DNS CNAME target=' + $dns.NameHost) }
} catch { Log ('DNS CNAME lookup failed: ' + $_.Exception.Message) }

if (($publicGet -in 0,502,504) -and ($publicPost -in 0,502,504)) {
    Log 'Public endpoint still does not reach the origin. cloudflared stderr tail:'
    Get-Content $errLog -Tail 120 -ErrorAction SilentlyContinue | ForEach-Object { Log $_ }

    $cert = @(
        'C:\Windows\System32\config\systemprofile\.cloudflared\cert.pem',
        'C:\Windows.old\Windows\System32\config\systemprofile\.cloudflared\cert.pem',
        'C:\Users\mgste\.cloudflared\cert.pem',
        'C:\Windows.old\Users\mgste\.cloudflared\cert.pem'
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($cert) {
        $env:TUNNEL_ORIGIN_CERT = $cert
        $help = (& $exe tunnel route dns --help 2>&1) -join "`n"
        if ($help -match '--overwrite-dns') {
            Log 'CLI supports --overwrite-dns and cert.pem exists. Normalizing mcp.matthewgsteel.com to this tunnel.'
            $route = & $exe tunnel route dns --overwrite-dns $tunnelId 'mcp.matthewgsteel.com' 2>&1
            Log ('DNS route result: ' + ($route -join ' '))
            Start-Sleep -Seconds 8
            $publicGet = Http-Probe 'https://mcp.matthewgsteel.com/mcp' 'GET'
            $publicPost = Http-Probe 'https://mcp.matthewgsteel.com/mcp' 'POST' $initBody
            Log ("Public after DNS normalization GET=$publicGet POST=$publicPost")
        } else {
            Log 'cert.pem exists but this cloudflared build does not advertise --overwrite-dns; no DNS mutation attempted.'
        }
    } else {
        Log 'No surviving cert.pem found; no DNS mutation attempted.'
    }
}

if (($publicGet -notin 0,502,504) -or ($publicPost -notin 0,502,504)) {
    @(
        'MGS public transport is reaching the MCP origin again.',
        ('Recovered: ' + (Get-Date -Format o)),
        ('Tunnel PID: ' + $p.Id),
        ('Tunnel UUID: ' + $tunnelId),
        ('Local GET/POST: ' + $localGet + '/' + $localPost),
        ('Public GET/POST: ' + $publicGet + '/' + $publicPost),
        ('Log: ' + $log)
    ) | Set-Content -LiteralPath (Join-Path $root 'MGS_BRIDGE_READY.txt') -Encoding ASCII
    Write-Host ''
    Write-Host 'SUCCESS: PUBLIC TRANSPORT IS REACHING THE MCP ORIGIN.' -ForegroundColor Green
    Write-Host ("Local GET/POST: $localGet/$localPost | Public GET/POST: $publicGet/$publicPost") -ForegroundColor Green
    Write-Host 'Tell ChatGPT: TEST NOW. Leave this window alone.' -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host 'V6 FINISHED BUT PUBLIC TRANSPORT IS STILL NOT REACHING THE MCP ORIGIN.' -ForegroundColor Red
    Write-Host ("Local GET/POST: $localGet/$localPost | Public GET/POST: $publicGet/$publicPost") -ForegroundColor Yellow
    Write-Host ('Exact diagnostics saved to: ' + $log) -ForegroundColor Yellow
    Write-Host 'Tell ChatGPT only: V6 FINISHED. No screenshot transcription needed.' -ForegroundColor Yellow
}
