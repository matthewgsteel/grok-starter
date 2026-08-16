$ErrorActionPreference='Continue'
Write-Host 'MGS MCP + CLOUDFLARE TARGETED REPAIR' -ForegroundColor Cyan
Write-Host 'No reboot. No cleanup. No file moves except restoring missing bridge files.' -ForegroundColor DarkGray

$base='C:\ProgramData\MGS-MCP'
$token=Join-Path $base 'bridge-token.txt'
$restart=Join-Path $base 'restart-mgs-mcp.ps1'
$run=Join-Path $base 'run-server.cmd'

Write-Host ''
Write-Host '[1] Repair missing MGS bridge token' -ForegroundColor Cyan
if(Test-Path $token){
  Write-Host 'bridge-token.txt already present.' -ForegroundColor Green
} else {
  $candidates=@(
    'C:\Windows.old\ProgramData\MGS-MCP\bridge-token.txt',
    'C:\Windows.old\Users\mgste\MGS-MCP\bridge-token.txt',
    'C:\Windows.old\Users\mgste\AppData\Local\MGS-MCP\bridge-token.txt'
  )
  $old=$candidates | Where-Object {Test-Path $_} | Select-Object -First 1
  if($old){
    New-Item -ItemType Directory -Force -Path $base | Out-Null
    Copy-Item -LiteralPath $old -Destination $token -Force
    Write-Host 'Restored original bridge token from Windows.old.' -ForegroundColor Green
  } else {
    New-Item -ItemType Directory -Force -Path $base | Out-Null
    $bytes=New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    ([BitConverter]::ToString($bytes).Replace('-','').ToLowerInvariant()) | Set-Content -LiteralPath $token -NoNewline -Encoding ascii
    Write-Host 'No old token survived; created a new local bridge token so the MCP server can start.' -ForegroundColor Yellow
  }
}

Write-Host ''
Write-Host '[2] Restart local MGS MCP origin' -ForegroundColor Cyan
if(Test-Path $restart){
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $restart
} elseif(Test-Path $run){
  Start-Process -FilePath $run -WorkingDirectory $base
} else {
  Write-Host 'MGS MCP startup helper missing.' -ForegroundColor Red
}
Start-Sleep -Seconds 6
$local=Get-NetTCPConnection -LocalPort 8765 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if($local){Write-Host ('Local MCP is listening on 8765, PID '+$local.OwningProcess) -ForegroundColor Green}else{Write-Host 'Local MCP is NOT listening on 8765.' -ForegroundColor Red}

Write-Host ''
Write-Host '[3] Revive Cloudflare tunnel' -ForegroundColor Cyan
$svc=Get-CimInstance Win32_Service -Filter "Name='cloudflared'" -ErrorAction SilentlyContinue
if(-not $svc){
  Write-Host 'cloudflared service registration is missing.' -ForegroundColor Red
} else {
  Write-Host ('cloudflared state: '+$svc.State)
  $pathName=[string]$svc.PathName
  $display=$pathName -replace '(?i)(--token\s+)(\S+)','$1[REDACTED]'
  Write-Host ('service command: '+$display)

  $exe=$null;$args=''
  if($pathName -match '^\s*"([^"]+\.exe)"\s*(.*)$'){$exe=$matches[1];$args=$matches[2]}
  elseif($pathName -match '^\s*([^\s]+\.exe)\s*(.*)$'){$exe=$matches[1];$args=$matches[2]}

  if($exe -and -not (Test-Path $exe)){
    $oldExe='C:\Windows.old'+$exe.Substring(2)
    if(Test-Path $oldExe){
      New-Item -ItemType Directory -Force -Path (Split-Path $exe -Parent) | Out-Null
      Copy-Item -LiteralPath $oldExe -Destination $exe -Force
      Write-Host 'Restored missing cloudflared executable from Windows.old.' -ForegroundColor Green
    }
  }

  if($svc.State -ne 'Running'){
    Start-Service cloudflared -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 4
    $svc2=Get-CimInstance Win32_Service -Filter "Name='cloudflared'" -ErrorAction SilentlyContinue
    if($svc2.State -eq 'Running'){
      Write-Host 'cloudflared service is running.' -ForegroundColor Green
    } elseif($exe -and (Test-Path $exe)) {
      Write-Host 'Service still would not start. Launching its existing tunnel command as a normal process...' -ForegroundColor Yellow
      try{Start-Process -FilePath $exe -ArgumentList $args -WindowStyle Hidden; Start-Sleep -Seconds 6}catch{}
    }
  }
}

Write-Host ''
Write-Host '[4] Final status' -ForegroundColor Cyan
$local=Get-NetTCPConnection -LocalPort 8765 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
$cf=Get-Process cloudflared -ErrorAction SilentlyContinue
Write-Host ('MCP 8765 listening: '+[bool]$local)
Write-Host ('cloudflared processes: '+@($cf).Count)
if(-not $local){
  Write-Host 'Recent MGS MCP error log:' -ForegroundColor Yellow
  Get-Content 'C:\ProgramData\MGS-MCP\server.error.log' -Tail 15 -ErrorAction SilentlyContinue
}
if(@($cf).Count -eq 0){
  Write-Host 'Recent Cloudflare service errors:' -ForegroundColor Yellow
  Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Service Control Manager';StartTime=(Get-Date).AddMinutes(-15)} -ErrorAction SilentlyContinue |
    Where-Object {$_.Message -match '(?i)cloudflared'} | Select-Object -First 8 | ForEach-Object {Write-Host ($_.TimeCreated.ToString('HH:mm:ss')+' ID '+$_.Id+' '+($_.Message -replace '\r?\n',' | '))}
}
Write-Host ''
Write-Host 'TARGETED REPAIR COMPLETE. Tell ChatGPT: test it again.' -ForegroundColor Green
