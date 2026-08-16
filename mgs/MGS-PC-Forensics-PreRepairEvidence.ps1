$ErrorActionPreference='Continue'
$ProgressPreference='SilentlyContinue'

$stamp=Get-Date -Format 'yyyyMMdd_HHmmss'
$desktop=[Environment]::GetFolderPath('Desktop')
if(-not $desktop){$desktop=Join-Path $env:USERPROFILE 'Desktop'}
$out=Join-Path $desktop ("MGS_PC_FORENSICS_PREREPAIR_$stamp")
$raw=Join-Path $out 'RawEventLogs'
$scripts=Join-Path $out 'Scripts'
$tasks=Join-Path $out 'Tasks'
New-Item -ItemType Directory -Force -Path $out,$raw,$scripts,$tasks | Out-Null
$err=Join-Path $out 'ERRORS.txt'
$day=(Get-Date).Date
$start=$day.AddDays(-1).AddHours(23).AddMinutes(30)
$end=$day.AddHours(2).AddMinutes(30)

function Step($n,$msg){Write-Host "[$n] $msg" -ForegroundColor Cyan}
function Save($name,[scriptblock]$body){
  $p=Join-Path $out ($name+'.txt')
  try{& $body 2>&1 | Out-String -Width 8192 | Out-File $p -Encoding utf8}catch{$_ | Out-File $err -Append -Encoding utf8}
}
function Redact([string]$s){
  if($null -eq $s){return $null}
  $x=$s
  $x=$x -replace '(?i)(gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]{12,})','[REDACTED_TOKEN]'
  $x=$x -replace '(?i)(token|secret|password|passwd|apikey|api_key)\s*[:=]\s*[^ ;,"''\r\n]+','$1=[REDACTED]'
  return $x
}
function ExportWindowFromEvtx($path,$label){
  if(-not (Test-Path -LiteralPath $path)){return}
  try{
    $safe=($label -replace '[\\/:*?"<>| ]','_')
    Copy-Item -LiteralPath $path -Destination (Join-Path $raw ($safe+'.evtx')) -Force -ErrorAction SilentlyContinue
    $events=Get-WinEvent -FilterHashtable @{Path=$path;StartTime=$start;EndTime=$end} -ErrorAction Stop | Select-Object TimeCreated,Id,LevelDisplayName,ProviderName,MachineName,Message
    $events | Export-Csv (Join-Path $out ($safe+'_INCIDENT.csv')) -NoTypeInformation -Encoding UTF8
    $events | Format-List * | Out-String -Width 8192 | Out-File (Join-Path $out ($safe+'_INCIDENT.txt')) -Encoding utf8
  }catch{"$label :: $($_.Exception.Message)" | Out-File $err -Append -Encoding utf8}
}
function SaveRedactedFile($path,$name){
  if(Test-Path -LiteralPath $path){
    try{Get-Content -LiteralPath $path -ErrorAction Stop | ForEach-Object {Redact $_} | Out-File (Join-Path $scripts $name) -Encoding utf8}catch{"$path :: $($_.Exception.Message)" | Out-File $err -Append -Encoding utf8}
  }
}
function ListPath($p){
  if(Test-Path -LiteralPath $p){
    "### $p"
    try{Get-Item -LiteralPath $p -Force | Select FullName,Length,CreationTime,LastWriteTime,Attributes,LinkType,Target | Format-List}catch{}
    try{Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | Select Name,FullName,Length,CreationTime,LastWriteTime,Attributes,LinkType,Target | Format-Table -AutoSize}catch{}
    ''
  } else {"MISSING: $p";''}
}

Step 1 'Read pre-repair Windows.old event logs around the incident'
$oldLogRoot='C:\Windows.old\Windows\System32\winevt\Logs'
$core=@(
  'System.evtx','Application.evtx','Setup.evtx',
  'Microsoft-Windows-TaskScheduler%4Operational.evtx',
  'Microsoft-Windows-WindowsUpdateClient%4Operational.evtx',
  'Microsoft-Windows-User Profile Service%4Operational.evtx',
  'Microsoft-Windows-Windows Defender%4Operational.evtx',
  'Microsoft-Windows-Shell-Core%4Operational.evtx',
  'Microsoft-Windows-AppXDeploymentServer%4Operational.evtx',
  'Microsoft-Windows-AppXDeployment-Server%4Operational.evtx'
)
foreach($n in $core){ExportWindowFromEvtx (Join-Path $oldLogRoot $n) ('OLD_'+[IO.Path]::GetFileNameWithoutExtension($n))}
if(Test-Path $oldLogRoot){
  Get-ChildItem $oldLogRoot -File -ErrorAction SilentlyContinue | Where-Object {$_.Name -match 'Storage|Storport|Disk|NTFS|Cloud|Profile|Cleanup|Servicing|Update|TaskScheduler'} | Select -First 40 | ForEach-Object {ExportWindowFromEvtx $_.FullName ('OLD_'+$_.BaseName)}
}

Step 2 'Query surviving current operational logs for the same incident window'
$logs=@(
 'Microsoft-Windows-TaskScheduler/Operational',
 'Microsoft-Windows-User Profile Service/Operational',
 'Microsoft-Windows-WindowsUpdateClient/Operational',
 'Microsoft-Windows-Shell-Core/Operational',
 'Microsoft-Windows-AppXDeploymentServer/Operational',
 'Microsoft-Windows-Windows Defender/Operational'
)
foreach($ln in $logs){
  try{
    $safe=($ln -replace '[\\/:*?"<>| ]','_')
    $ev=Get-WinEvent -FilterHashtable @{LogName=$ln;StartTime=$start;EndTime=$end} -ErrorAction Stop | Select TimeCreated,Id,LevelDisplayName,ProviderName,MachineName,Message
    $ev | Export-Csv (Join-Path $out ('CURRENT_'+$safe+'_INCIDENT.csv')) -NoTypeInformation -Encoding UTF8
  }catch{"$ln :: $($_.Exception.Message)" | Out-File $err -Append -Encoding utf8}
}
try{
  Get-WinEvent -ListLog * -ErrorAction SilentlyContinue | Where-Object {$_.IsEnabled -and $_.LogName -match 'Storage|Disk|NTFS|Cleanup|StorageSense'} | Select LogName,RecordCount,FileSize,LogFilePath | Format-Table -AutoSize | Out-File (Join-Path $out 'CURRENT_STORAGE_LOG_LIST.txt') -Encoding utf8
}catch{}

Step 3 'Read old and current Desktop known-folder mappings'
Save 'PROFILE_MAPPINGS_CURRENT_AND_OLD' {
  'CURRENT HKCU User Shell Folders:'
  Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction SilentlyContinue | Format-List *
  '';'CURRENT HKCU Shell Folders:'
  Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders' -ErrorAction SilentlyContinue | Format-List *
  '';'OLD Windows.old NTUSER.DAT:'
  $hive='C:\Windows.old\Users\mgste\NTUSER.DAT'
  if(Test-Path $hive){
    & reg.exe unload HKU\MGS_OLD_PROFILE 2>$null | Out-Null
    $load=& reg.exe load HKU\MGS_OLD_PROFILE $hive 2>&1
    $load
    if($LASTEXITCODE -eq 0){
      & reg.exe query 'HKU\MGS_OLD_PROFILE\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' /s 2>&1
      & reg.exe query 'HKU\MGS_OLD_PROFILE\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders' /s 2>&1
      & reg.exe unload HKU\MGS_OLD_PROFILE 2>&1
    }
  } else {'OLD NTUSER.DAT missing'}
}

Step 4 'Inspect tasks that ran at the critical time'
$taskSpecs=@(
  @{Path='\';Name='MGS Unattended Reboot Guard'},
  @{Path='\';Name='MGS VistaPrint MCP Cutover'},
  @{Path='\';Name='MGS Proton Startup Supervisor'},
  @{Path='\';Name='MGS Browser Controller Brave Launcher'},
  @{Path='\Microsoft\Windows\DiskCleanup\';Name='SilentCleanup'},
  @{Path='\Microsoft\Windows\DiskFootprint\';Name='StorageSense'}
)
Save 'CRITICAL_TASKS' {
  foreach($s in $taskSpecs){
    "### $($s.Path)$($s.Name)"
    try{
      $t=Get-ScheduledTask -TaskPath $s.Path -TaskName $s.Name -ErrorAction Stop
      $i=Get-ScheduledTaskInfo -TaskPath $s.Path -TaskName $s.Name -ErrorAction SilentlyContinue
      $t | Select TaskPath,TaskName,State,Author,Description | Format-List
      $i | Format-List LastRunTime,LastTaskResult,NextRunTime,NumberOfMissedRuns
      'Triggers:';$t.Triggers | Format-List *
      'Actions:';$t.Actions | ForEach-Object {[pscustomobject]@{Execute=$_.Execute;Arguments=(Redact $_.Arguments);WorkingDirectory=$_.WorkingDirectory}} | Format-List
      Export-ScheduledTask -TaskPath $s.Path -TaskName $s.Name | Out-File (Join-Path $tasks (($s.Name -replace '[\\/:*?"<>| ]','_')+'.xml')) -Encoding utf8
    }catch{$_.Exception.Message}
    ''
  }
}

Step 5 'Capture the local MGS scripts and scan automation for destructive operations'
$important=@(
 'C:\ProgramData\MGS-MCP\proton-startup-supervisor\Abort-Unattended-System-Reboot.ps1',
 'C:\ProgramData\MGS-MCP\proton-startup-supervisor\Proton-Startup-Supervisor.ps1',
 'C:\ProgramData\MGS-MCP\vistaprint-cutover.ps1',
 'C:\Windows.old\ProgramData\MGS-MCP\proton-startup-supervisor\Abort-Unattended-System-Reboot.ps1',
 'C:\Windows.old\ProgramData\MGS-MCP\proton-startup-supervisor\Proton-Startup-Supervisor.ps1',
 'C:\Windows.old\ProgramData\MGS-MCP\vistaprint-cutover.ps1'
)
foreach($p in $important){SaveRedactedFile $p (($p -replace '[:\\ ]','_')+'.txt')}
Save 'MGS_AUTOMATION_METADATA_AND_DESTRUCTIVE_MATCHES' {
  $root='C:\ProgramData\MGS-MCP'
  if(Test-Path $root){
    'Recently modified automation files:'
    Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue | Where-Object {$_.Extension -match '^\.(ps1|psm1|cmd|bat)$' -and $_.LastWriteTime -ge $day.AddDays(-2)} | Select FullName,Length,CreationTime,LastWriteTime | Sort LastWriteTime | Format-Table -AutoSize
    '';'Potentially destructive or reboot-related lines:'
    $patterns='Remove-Item|Clear-Content|Move-Item|Rename-Item|robocopy|rmdir|rd /s|del /|erase |Remove-Appx|winget.+uninstall|msiexec.+/x|cleanmgr|StorageSense|shutdown|Restart-Computer|Stop-Computer|Desktop|AppData\\Local\\Programs|Program Files|Windows.old'
    Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue | Where-Object {$_.Extension -match '^\.(ps1|psm1|cmd|bat)$'} | Select-String -Pattern $patterns -ErrorAction SilentlyContinue | ForEach-Object {[pscustomobject]@{Path=$_.Path;LineNumber=$_.LineNumber;Line=(Redact $_.Line)}} | Format-Table -Wrap -AutoSize
  } else {'C:\ProgramData\MGS-MCP is missing'}
}

Step 6 'Inspect browser, Proton, MGS and Windows.old payloads'
Save 'PAYLOAD_DIRECTORY_STATE' {
  $paths=@(
   'C:\Program Files\BraveSoftware\Brave-Browser\Application',
   'C:\Program Files\Google\Chrome\Application',
   'C:\Program Files (x86)\Microsoft\Edge\Application',
   (Join-Path $env:LOCALAPPDATA 'Programs\Proton\Drive'),
   (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data'),
   'C:\ProgramData\MGS-MCP',
   'C:\ProgramData\DeveloperTools',
   'C:\Windows.old\Program Files\BraveSoftware\Brave-Browser\Application',
   'C:\Windows.old\Program Files\Google\Chrome\Application',
   'C:\Windows.old\Program Files (x86)\Microsoft\Edge\Application',
   'C:\Windows.old\ProgramData\MGS-MCP',
   'C:\Windows.old\ProgramData\DeveloperTools',
   'C:\Windows.old\Users\mgste\AppData\Local\Programs\Proton\Drive'
  )
  foreach($p in $paths){ListPath $p}
}

Step 7 'Preserve browser session metadata without copying browsing history'
Save 'BROWSER_SESSION_METADATA' {
  $roots=@((Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data'),(Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'))
  foreach($r in $roots){
    "### $r"
    if(Test-Path $r){
      Get-ChildItem $r -Directory -ErrorAction SilentlyContinue | Where-Object {$_.Name -eq 'Default' -or $_.Name -like 'Profile *'} | ForEach-Object {
        $sess=Join-Path $_.FullName 'Sessions'
        if(Test-Path $sess){
          "Sessions: $sess"
          Get-ChildItem $sess -File -Force -ErrorAction SilentlyContinue | ForEach-Object {$h='';try{$h=(Get-FileHash $_.FullName -Algorithm SHA256).Hash}catch{};[pscustomobject]@{FullName=$_.FullName;Length=$_.Length;CreationTime=$_.CreationTime;LastWriteTime=$_.LastWriteTime;SHA256=$h}} | Format-Table -AutoSize
        }
      }
    }
  }
}

Step 8 'Inspect Storage Sense trigger data and cleanup task history'
Save 'STORAGE_SENSE_DEEP' {
  $p='HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
  $v=Get-ItemProperty $p -ErrorAction SilentlyContinue
  $v | Format-List *
  foreach($n in @('StoragePoliciesLastTrigger','StoragePoliciesLastFailure')){
    $b=$v.$n
    if($b){
      "$n length=$($b.Length) hex=$(($b|ForEach-Object {$_.ToString('X2')}) -join '')"
      if($b.Length -ge 8){
        try{$ft=[BitConverter]::ToInt64([byte[]]$b,0);$d=[DateTime]::FromFileTimeUtc($ft);"$n first8_as_FILETIME_UTC=$d"}catch{}
      }
    }
  }
  ''
  foreach($s in @(@{Path='\Microsoft\Windows\DiskCleanup\';Name='SilentCleanup'},@{Path='\Microsoft\Windows\DiskFootprint\';Name='StorageSense'})){
    try{Get-ScheduledTaskInfo -TaskPath $s.Path -TaskName $s.Name | Select @{n='Task';e={$s.Path+$s.Name}},LastRunTime,LastTaskResult,NextRunTime,NumberOfMissedRuns | Format-List}catch{$_.Exception.Message}
  }
}

Step 9 'Inspect current and old prefetch execution traces around midnight'
Save 'PREFETCH_METADATA' {
  foreach($root in @('C:\Windows\Prefetch','C:\Windows.old\Windows\Prefetch')){
    "### $root"
    if(Test-Path $root){
      Get-ChildItem $root -File -Filter '*.pf' -ErrorAction SilentlyContinue | Where-Object {$_.LastWriteTime -ge $start -and $_.LastWriteTime -le $end -or $_.Name -match 'POWERSHELL|CLEANMGR|SETUPHOST|DISM|MOUSO|SYSTEMSETTINGS|STORAGE|ROBOCOPY|CMD.EXE'} | Select Name,FullName,Length,CreationTime,LastWriteTime | Sort LastWriteTime | Format-Table -AutoSize
    }
  }
}

Step 10 'Copy pre-repair Panther logs if present'
foreach($src in @(
 'C:\Windows.old\Windows\Panther\setupact.log','C:\Windows.old\Windows\Panther\setuperr.log',
 'C:\Windows.old\$WINDOWS.~BT\Sources\Panther\setupact.log','C:\Windows.old\$WINDOWS.~BT\Sources\Panther\setuperr.log',
 'C:\$WINDOWS.~BT\Sources\Panther\setupact.log','C:\$WINDOWS.~BT\Sources\Panther\setuperr.log'
)){
  try{if(Test-Path -LiteralPath $src){Copy-Item -LiteralPath $src -Destination (Join-Path $out (($src -replace '[\\/:*?"<>| ]','_')+'.txt')) -Force}}catch{}
}

Step 11 'Create ZIP'
Save '00_SUMMARY' {
  "Incident window: $start through $end"
  "Computer=$env:COMPUTERNAME User=$env:USERNAME Profile=$env:USERPROFILE"
  "Windows.old exists=$(Test-Path 'C:\Windows.old')"
  "Current Desktop=$([Environment]::GetFolderPath('Desktop'))"
  "Current Desktop items=$(@(Get-ChildItem (Join-Path $env:USERPROFILE 'Desktop') -Force -ErrorAction SilentlyContinue).Count)"
  "Old Desktop items=$(@(Get-ChildItem 'C:\Windows.old\Users\mgste\Desktop' -Force -ErrorAction SilentlyContinue).Count)"
}
$zip=Join-Path $desktop ("MGS_PC_FORENSICS_PREREPAIR_$stamp.zip")
Compress-Archive -Path (Join-Path $out '*') -DestinationPath $zip -CompressionLevel Optimal -Force
Write-Host ''
Write-Host '============================================================' -ForegroundColor Green
Write-Host 'MGS PRE-REPAIR EVIDENCE COLLECTION COMPLETE' -ForegroundColor Green
Write-Host ("ZIP: {0}" -f $zip) -ForegroundColor Green
Write-Host '============================================================' -ForegroundColor Green
Read-Host 'Press Enter to close'
