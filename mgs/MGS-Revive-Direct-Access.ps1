$ErrorActionPreference='Continue'
Write-Host 'MGS DIRECT ACCESS REVIVE' -ForegroundColor Cyan
Write-Host 'No reboot. No cleanup. No file moves.' -ForegroundColor DarkGray

$restart='C:\ProgramData\MGS-MCP\restart-mgs-mcp.ps1'
$run='C:\ProgramData\MGS-MCP\run-server.cmd'

Write-Host ('restart script present: ' + (Test-Path $restart))
Write-Host ('run-server present:     ' + (Test-Path $run))

$cfSvc=Get-Service cloudflared -ErrorAction SilentlyContinue
$cfProc=Get-Process cloudflared -ErrorAction SilentlyContinue
if($cfSvc){Write-Host ('cloudflared service:   ' + $cfSvc.Status)}else{Write-Host 'cloudflared service:   not registered'}
Write-Host ('cloudflared processes:  ' + @($cfProc).Count)

if($cfSvc -and $cfSvc.Status -eq 'Stopped'){
  Write-Host 'Starting existing cloudflared service...'
  Start-Service cloudflared -ErrorAction Continue
  Start-Sleep -Seconds 2
}

if(Test-Path $restart){
  Write-Host 'Running existing MGS-MCP restart helper...'
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $restart
} elseif(Test-Path $run){
  Write-Host 'Starting existing MGS-MCP run-server.cmd...'
  Start-Process -FilePath $run -WorkingDirectory (Split-Path $run -Parent)
} else {
  Write-Host 'MGS-MCP startup files are missing from C:\ProgramData\MGS-MCP' -ForegroundColor Red
}

Start-Sleep -Seconds 6
Write-Host ''
Write-Host 'Listening ports of interest:' -ForegroundColor Cyan
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
  Where-Object {$_.LocalPort -in 8765,8766,8789,8790,8791,9222,18789} |
  Select-Object LocalAddress,LocalPort,OwningProcess |
  Sort-Object LocalPort |
  Format-Table -AutoSize

Write-Host ''
Write-Host 'MGS-MCP recent logs:' -ForegroundColor Cyan
foreach($p in @('C:\ProgramData\MGS-MCP\server.error.log','C:\ProgramData\MGS-MCP\server.log')){
  if(Test-Path $p){Write-Host ('--- '+$p); Get-Content $p -Tail 12 -ErrorAction SilentlyContinue}
}
Write-Host ''
Write-Host 'REVIVE ATTEMPT COMPLETE. Tell ChatGPT to test the MGS bridge now.' -ForegroundColor Green
