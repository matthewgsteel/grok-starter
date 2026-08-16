$ErrorActionPreference='Stop'
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
  $listener=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any,$port)
  $listener.Start()
  Write-Host ''
  Write-Host 'MGS LOCAL TRANSFER READY' -ForegroundColor Green
  Write-Host "File: $($zip.FullName)"
  Write-Host "Size: $([math]::Round($zip.Length/1MB,1)) MB"
  Write-Host "SHA256: $((Get-FileHash -LiteralPath $zip.FullName -Algorithm SHA256).Hash)"
  Write-Host ''
  Write-Host 'On your iPhone, while connected to the SAME Wi-Fi, open Safari and enter:' -ForegroundColor Cyan
  Write-Host "http://$ip`:$port/" -ForegroundColor Yellow
  Write-Host ''
  Write-Host 'This server is LAN-only and will shut itself down after one successful download.'
  Write-Host 'Waiting for the iPhone...'

  while($true){
    $client=$listener.AcceptTcpClient()
    try {
      $stream=$client.GetStream()
      $reader=New-Object System.IO.StreamReader($stream,[Text.Encoding]::ASCII,$false,4096,$true)
      $request=$reader.ReadLine()
      while(($line=$reader.ReadLine()) -ne $null -and $line -ne ''){}
      if($request -notmatch '^GET '){
        $resp=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 405 Method Not Allowed`r`nConnection: close`r`nContent-Length: 0`r`n`r`n")
        $stream.Write($resp,0,$resp.Length)
        continue
      }
      $name=$zip.Name.Replace('"','')
      $header="HTTP/1.1 200 OK`r`nContent-Type: application/zip`r`nContent-Disposition: attachment; filename=\"$name\"`r`nContent-Length: $($zip.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
      $hb=[Text.Encoding]::ASCII.GetBytes($header)
      $stream.Write($hb,0,$hb.Length)
      $fs=[IO.File]::OpenRead($zip.FullName)
      try{$fs.CopyTo($stream)}finally{$fs.Dispose()}
      $stream.Flush()
      Write-Host ''
      Write-Host 'DOWNLOAD SENT SUCCESSFULLY. Local server is shutting down.' -ForegroundColor Green
      break
    } finally {
      $client.Close()
    }
  }
} finally {
  if($listener){$listener.Stop()}
  Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
}
