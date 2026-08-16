$ErrorActionPreference='Continue'
Write-Host 'MGS CLOUDFLARE LAST-MILE RECOVERY' -ForegroundColor Cyan
Write-Host 'No reboot. No cleanup. No Proton changes.' -ForegroundColor DarkGray

$exe='C:\Program Files (x86)\cloudflared\cloudflared.exe'
$cfgDir='C:\Windows\System32\config\systemprofile\.cloudflared'
$cfg=Join-Path $cfgDir 'config.yml'
$oldDir='C:\Windows.old\Windows\System32\config\systemprofile\.cloudflared'
$stamp=Get-Date -Format 'yyyyMMdd_HHmmss'
$logRoot=if(Test-Path 'D:\'){'D:\'}else{$env:TEMP}
$outLog=Join-Path $logRoot ("MGS_cloudflared_stdout_$stamp.txt")
$errLog=Join-Path $logRoot ("MGS_cloudflared_stderr_$stamp.txt")

Write-Host ''
Write-Host '[1] Current files' -ForegroundColor Cyan
Write-Host ('cloudflared.exe exists: '+(Test-Path $exe))
Write-Host ('config.yml exists:      '+(Test-Path $cfg))
if(Test-Path $cfgDir){Get-ChildItem $cfgDir -Force | Select-Object Name,Length,LastWriteTime | Format-Table -AutoSize}

Write-Host ''
Write-Host '[2] Restore only missing tunnel support files from Windows.old' -ForegroundColor Cyan
if(Test-Path $oldDir){
  New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
  foreach($f in Get-ChildItem $oldDir -File -Force -ErrorAction SilentlyContinue){
    $dest=Join-Path $cfgDir $f.Name
    if(-not (Test-Path $dest)){
      Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
      Write-Host ('Restored missing: '+$f.Name) -ForegroundColor Green
    }
  }
}else{
  Write-Host 'No old systemprofile .cloudflared directory found.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '[3] Validate config and credential target' -ForegroundColor Cyan
if(Test-Path $cfg){
  $text=Get-Content $cfg -Raw
  $safe=$text -replace '(?im)^\s*token\s*:.*$','token: [REDACTED]'
  Write-Host 'config.yml:'
  Write-Host $safe
  $cred=$null
  if($text -match '(?im)^\s*credentials-file\s*:\s*["'']?([^\r\n"'']+)'){$cred=$matches[1].Trim()}
  if($cred){
    Write-Host ('credentials-file: '+$cred)
    Write-Host ('credentials exists: '+(Test-Path $cred))
    if(-not (Test-Path $cred)){
      $name=Split-Path $cred -Leaf
      $oldCred=Join-Path $oldDir $name
      if(Test-Path $oldCred){
        New-Item -ItemType Directory -Force -Path (Split-Path $cred -Parent) | Out-Null
        Copy-Item -LiteralPath $oldCred -Destination $cred -Force
        Write-Host 'Restored the credential JSON referenced by config.yml.' -ForegroundColor Green
      }
    }
  } else {
    Write-Host 'No credentials-file entry found in config.yml.' -ForegroundColor Yellow
  }
}else{
  Write-Host 'config.yml is missing.' -ForegroundColor Red
}

if((Test-Path $exe) -and (Test-Path $cfg)){
  Write-Host ''
  Write-Host '[4] Cloudflare ingress validation' -ForegroundColor Cyan
  & $exe --config=$cfg tunnel ingress validate

  Write-Host ''
  Write-Host '[5] Launch tunnel directly and capture the real error' -ForegroundColor Cyan
  Get-Process cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 1
  $p=Start-Process -FilePath $exe -ArgumentList @("--config=$cfg",'tunnel','run') -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru -WindowStyle Hidden
  Start-Sleep -Seconds 8
  if(-not $p.HasExited){
    Write-Host ('SUCCESS: cloudflared is still running, PID '+$p.Id) -ForegroundColor Green
    Write-Host 'Leaving it running so ChatGPT can test the public bridge.' -ForegroundColor Green
  }else{
    Write-Host ('cloudflared exited with code '+$p.ExitCode) -ForegroundColor Red
    Write-Host '--- STDERR ---' -ForegroundColor Yellow
    Get-Content $errLog -Tail 40 -ErrorAction SilentlyContinue
    Write-Host '--- STDOUT ---' -ForegroundColor Yellow
    Get-Content $outLog -Tail 40 -ErrorAction SilentlyContinue
  }
}else{
  Write-Host 'Cannot launch because executable or config is missing.' -ForegroundColor Red
}

Write-Host ''
Write-Host ('stdout log: '+$outLog)
Write-Host ('stderr log: '+$errLog)
Write-Host 'LAST-MILE CHECK COMPLETE. If SUCCESS appeared, tell ChatGPT: test now.' -ForegroundColor Green
