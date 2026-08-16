$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$port=8769
$rule='MGS Forensics Temporary LAN Transfer'
$desktop=[Environment]::GetFolderPath('Desktop')
$downloads=Join-Path $env:USERPROFILE 'Downloads'
$zip=Get-ChildItem -Path $desktop,$downloads -Filter 'MGS_PC_FORENSICS_*.zip' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if(-not $zip){throw 'No MGS_PC_FORENSICS_*.zip found on Desktop or Downloads.'}
$cfg=Get-NetIPConfiguration | Where-Object {$_.IPv4DefaultGateway -and $_.IPv4Address} | Select-Object -First 1
if(-not $cfg){throw 'Could not determine the PC LAN IPv4 address.'}
$ip=$cfg.IPv4Address.IPAddress
try {
  Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
  New-NetFirewallRule -DisplayName $rule -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -RemoteAddress LocalSubnet -Profile Any | Out-Null
  $listener=New-Object System.Net.HttpListener
  $listener.Prefixes.Add(('http://+:{0}/' -f $port))
  $listener.Start()
  Write-Host ''
  Write-Host 'MGS LOCAL TRANSFER READY' -ForegroundColor Green
  Write-Host ('File: {0}' -f $zip.FullName)
  Write-Host ('Size: {0} MB' -f [math]::Round($zip.Length/1MB,1))
  Write-Host ('SHA256: {0}' -f (Get-FileHash -LiteralPath $zip.FullName -Algorithm SHA256).Hash)
  Write-Host ''
  Write-Host 'On your iPhone, while connected to the SAME Wi-Fi, open any browser and enter:' -ForegroundColor Cyan
  Write-Host ('http://{0}:{1}/' -f $ip,$port) -ForegroundColor Yellow
  Write-Host ''
  Write-Host 'This temporary server shuts down after one successful download.'
  Write-Host 'Waiting for the iPhone...'

  $ctx=$listener.GetContext()
  $ctx.Response.StatusCode=200
  $ctx.Response.ContentType='application/zip'
  $ctx.Response.ContentLength64=$zip.Length
  $ctx.Response.AddHeader('Content-Disposition',('attachment; filename="{0}"' -f $zip.Name))
  $ctx.Response.AddHeader('Cache-Control','no-store')
  $fs=[IO.File]::OpenRead($zip.FullName)
  try{$fs.CopyTo($ctx.Response.OutputStream)}finally{$fs.Dispose()}
  $ctx.Response.OutputStream.Close()
  $ctx.Response.Close()
  Write-Host ''
  Write-Host 'DOWNLOAD SENT SUCCESSFULLY. Local server is shutting down.' -ForegroundColor Green
} finally {
  if($listener -and $listener.IsListening){$listener.Stop();$listener.Close()}
  Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
}
