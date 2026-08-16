$ErrorActionPreference='Continue'
$ProgressPreference='SilentlyContinue'

$stamp=Get-Date -Format 'yyyyMMdd_HHmmss'
$desktop=[Environment]::GetFolderPath('Desktop')
if(-not $desktop){$desktop=Join-Path $env:USERPROFILE 'Desktop'}
$out=Join-Path $desktop "MGS_PC_FORENSICS_FAST_$stamp"
$evtx=Join-Path $out 'EVTX'
$logs=Join-Path $out 'Logs'
New-Item -ItemType Directory -Force -Path $out,$evtx,$logs | Out-Null
$err=Join-Path $out 'ERRORS.txt'

function Step($n,$msg){Write-Host "[$n] $msg" -ForegroundColor Cyan}
function Save($name,[scriptblock]$body){
  $p=Join-Path $out ($name+'.txt')
  try{& $body 2>&1 | Out-String -Width 4096 | Out-File $p -Encoding utf8}catch{$_ | Out-File $err -Append -Encoding utf8}
}
function Evtx($log,$name){
  try{$q='*[System[TimeCreated[timediff(@SystemTime) <= 259200000]]]'; wevtutil epl "$log" (Join-Path $evtx ($name+'.evtx')) "/q:$q" /ow:true 2>>$err}catch{}
}
function PathInfo($p){
  try{$i=Get-Item -LiteralPath $p -Force -ErrorAction Stop;[pscustomobject]@{Path=$p;Exists=$true;Type=if($i.PSIsContainer){'Directory'}else{'File'};Attributes=[string]$i.Attributes;LinkType=$i.LinkType;Target=($i.Target -join ';');Created=$i.CreationTime;Modified=$i.LastWriteTime}}catch{[pscustomobject]@{Path=$p;Exists=$false;Error=$_.Exception.Message}}
}
function Redact($s){if($null-eq$s){return $null};$x=[string]$s;$x=$x -replace '(?i)(gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]{12,})','[REDACTED_TOKEN]';$x=$x -replace '(?i)(token|secret|password|passwd|apikey|api_key)\s*[:=]\s*[^ ;,"\r\n]+','$1=[REDACTED]';$x}

Step 1 'System, OS, storage and disk health'
Save '01_SYSTEM' {
  Get-Date; whoami /all; systeminfo
  Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue | Format-List ProductName,DisplayVersion,CurrentBuild,CurrentBuildNumber,UBR,EditionID,InstallDate
}
Save '02_STORAGE_DISK_HEALTH' {
  Get-Volume | Format-Table DriveLetter,FileSystemLabel,FileSystem,HealthStatus,OperationalStatus,Size,SizeRemaining -AutoSize
  Get-Disk | Format-List Number,FriendlyName,SerialNumber,BusType,PartitionStyle,HealthStatus,OperationalStatus,Size
  Get-PhysicalDisk | Format-List FriendlyName,SerialNumber,MediaType,BusType,HealthStatus,OperationalStatus,Size,FirmwareVersion
  Get-PhysicalDisk | ForEach-Object {"### $($_.FriendlyName)";try{$_|Get-StorageReliabilityCounter|Format-List *}catch{$_.Exception.Message}}
  cmd /c 'fsutil dirty query C:'
  vssadmin list shadows
  vssadmin list shadowstorage
}

Step 2 'Profile, Desktop mappings, Windows.old and Proton state'
Save '03_PROFILE_PATHS' {
  "USERPROFILE=$env:USERPROFILE"
  "DesktopKnownFolder=$([Environment]::GetFolderPath('Desktop'))"
  Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction SilentlyContinue | Format-List *
  Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders' -ErrorAction SilentlyContinue | Format-List *
  Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue | ForEach-Object {$v=Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue;[pscustomobject]@{SID=$_.PSChildName;ProfileImagePath=$v.ProfileImagePath;State=$v.State;RefCount=$v.RefCount;Flags=$v.Flags}} | Format-Table -AutoSize
  Get-CimInstance Win32_UserProfile | Select LocalPath,Loaded,Special,Status,LastUseTime,SID | Format-Table -AutoSize
  ''
  'Target paths:'
  @($env:USERPROFILE,(Join-Path $env:USERPROFILE 'Desktop'),(Join-Path $env:USERPROFILE 'Documents'),(Join-Path $env:USERPROFILE 'Downloads'),(Join-Path $env:USERPROFILE 'Proton Drive'),'C:\Windows.old',("C:\Windows.old\Users\$env:USERNAME\Desktop")) | ForEach-Object {PathInfo $_} | Format-Table -AutoSize
  ''
  'User profile top level:'
  Get-ChildItem -LiteralPath $env:USERPROFILE -Force -ErrorAction SilentlyContinue | Select Name,FullName,Attributes,Length,CreationTime,LastWriteTime,LinkType,Target | Format-Table -AutoSize
  ''
  'Current Desktop:'
  Get-ChildItem -LiteralPath (Join-Path $env:USERPROFILE 'Desktop') -Force -ErrorAction SilentlyContinue | Select Name,FullName,Attributes,Length,CreationTime,LastWriteTime | Format-Table -AutoSize
  ''
  'Windows.old Desktop:'
  Get-ChildItem -LiteralPath ("C:\Windows.old\Users\$env:USERNAME\Desktop") -Force -ErrorAction SilentlyContinue | Select Name,FullName,Attributes,Length,CreationTime,LastWriteTime | Format-Table -AutoSize
  ''
  'Proton Drive root only, NO recursion:'
  Get-ChildItem -LiteralPath (Join-Path $env:USERPROFILE 'Proton Drive') -Force -ErrorAction SilentlyContinue | Select -First 500 Name,FullName,Attributes,Length,CreationTime,LastWriteTime,LinkType,Target | Format-Table -AutoSize
}
Save '04_ACLS' {
  @($env:USERPROFILE,(Join-Path $env:USERPROFILE 'Desktop'),(Join-Path $env:USERPROFILE 'Documents'),(Join-Path $env:USERPROFILE 'Downloads'),(Join-Path $env:USERPROFILE 'Proton Drive')) | ForEach-Object {"### $_";try{Get-Acl -LiteralPath $_|Format-List Owner,Sddl,AccessToString}catch{$_.Exception.Message}}
}

Step 3 'Installed programs, AppX registrations, browsers'
Save '05_INSTALLED_APPS' {
  $u=@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
  Get-ItemProperty $u -ErrorAction SilentlyContinue | Where-Object DisplayName | Select DisplayName,DisplayVersion,Publisher,InstallDate,InstallLocation,UninstallString | Sort DisplayName | Format-Table -AutoSize
}
Save '06_APPX' {
  Get-AppxPackage | Select Name,PackageFullName,PackageFamilyName,InstallLocation,Status,SignatureKind,IsFramework,NonRemovable | Sort Name | Format-Table -AutoSize
  ''
  'ChatGPT/OpenAI:'
  Get-AppxPackage | Where-Object {$_.Name -match 'OpenAI|ChatGPT'} | Format-List *
  ''
  'Provisioned:'
  Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Select DisplayName,PackageName,Version,InstallLocation | Sort DisplayName | Format-Table -AutoSize
}
Save '07_BROWSER_PATHS' {
  @('C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe','C:\Program Files (x86)\BraveSoftware\Brave-Browser\Application\brave.exe',(Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\Application\brave.exe'),(Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data'),'C:\Program Files\Google\Chrome\Application\chrome.exe','C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',(Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'),(Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')) | ForEach-Object {PathInfo $_} | Format-Table -AutoSize
}

Step 4 'Startup, scheduled tasks, OpenClaw/Sentinel/MGS state'
Save '08_TASKS_STARTUP_MGS' {
  'Startup commands:'; Get-CimInstance Win32_StartupCommand | Select Name,Command,Location,User | Format-Table -AutoSize
  '';'Relevant scheduled tasks:'
  Get-ScheduledTask | Where-Object {($_.TaskName+$_.TaskPath) -match 'MGS|MCP|Sentinel|OpenClaw|Cloudflare|Proton|Brave|Chrome'} | ForEach-Object {$info=Get-ScheduledTaskInfo -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue;[pscustomobject]@{TaskPath=$_.TaskPath;TaskName=$_.TaskName;State=$_.State;LastRunTime=$info.LastRunTime;LastTaskResult=$info.LastTaskResult;NextRunTime=$info.NextRunTime;Actions=(($_.Actions|ForEach-Object {Redact("$($_.Execute) $($_.Arguments)")}) -join ' || ')}} | Format-Table -Wrap -AutoSize
  '';'Relevant services:'
  Get-Service | Where-Object {$_.Name -match 'MGS|MCP|Sentinel|OpenClaw|Cloudflare|Proton|Brave|Chrome' -or $_.DisplayName -match 'MGS|MCP|Sentinel|OpenClaw|Cloudflare|Proton|Brave|Chrome'} | Format-Table Name,DisplayName,Status,StartType -AutoSize
  '';'Relevant processes:'
  Get-CimInstance Win32_Process | Where-Object {$_.Name -match 'powershell|pwsh|node|cloudflared|brave|chrome|proton|openclaw'} | ForEach-Object {[pscustomobject]@{Name=$_.Name;PID=$_.ProcessId;PPID=$_.ParentProcessId;ExecutablePath=$_.ExecutablePath;CommandLine=Redact($_.CommandLine)}} | Format-Table -Wrap -AutoSize
  '';'Known paths:'
  @('C:\ProgramData\MGS-GroupMe-Monitor','C:\ProgramData\MGS-Browser-Controller','C:\ProgramData\MGS',(Join-Path $env:USERPROFILE '.cloudflared'),(Join-Path $env:USERPROFILE '.openclaw'),'C:\SentinelCore',(Join-Path $env:USERPROFILE 'MGS-MCP'),(Join-Path $env:USERPROFILE 'MGS-MCP-Projects'),(Join-Path $env:APPDATA 'npm\openclaw.cmd')) | ForEach-Object {PathInfo $_} | Format-Table -AutoSize
  '';'Known ports:'
  Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object {$_.LocalPort -in 8765,8766,8789,8790,8791,9222,18789} | Select LocalAddress,LocalPort,OwningProcess | Sort LocalPort | Format-Table -AutoSize
}
Save '09_MGS_PUBLIC_CONNECTIVITY' {
  Resolve-DnsName mcp.matthewgsteel.com -ErrorAction SilentlyContinue
  Test-NetConnection mcp.matthewgsteel.com -Port 443 -InformationLevel Detailed
  try{$r=Invoke-WebRequest 'https://mcp.matthewgsteel.com/mcp' -Method Get -UseBasicParsing -TimeoutSec 15;"HTTP=$($r.StatusCode)";($r.Headers|Out-String)}catch{$_.Exception.ToString();if($_.Exception.Response){"HTTP="+[int]$_.Exception.Response.StatusCode}}
}

Step 5 'Storage Sense, recovery, Defender and update history'
Save '10_STORAGE_SENSE_RECOVERY' {
  'StorageSense:'; Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' -ErrorAction SilentlyContinue | Format-List *
  '';'Recovery:'; reagentc /info; try{Get-ComputerRestorePoint|Format-Table -AutoSize}catch{$_.Exception.Message}
}
Save '11_DEFENDER' {try{Get-MpComputerStatus|Format-List *}catch{$_.Exception.Message};'';'Threat detections:';try{Get-MpThreatDetection|Sort InitialDetectionTime -Descending|Format-List *}catch{$_.Exception.Message}}
Save '12_WINDOWS_UPDATE' {
  try{$s=New-Object -ComObject Microsoft.Update.Session;$sr=$s.CreateUpdateSearcher();$c=$sr.GetTotalHistoryCount();$sr.QueryHistory(0,[Math]::Min($c,250))|Select Date,Title,Description,Operation,ResultCode,HResult,ClientApplicationID|Format-Table -Wrap -AutoSize}catch{$_.Exception.ToString()}
  '';Get-HotFix|Sort InstalledOn -Descending|Select -First 100|Format-Table -AutoSize
}

Step 6 'Reliability records and 72-hour Windows event logs'
Save '13_RELIABILITY' {try{Get-CimInstance Win32_ReliabilityRecords|Where-Object {$_.TimeGenerated -ge (Get-Date).AddDays(-7)}|Sort TimeGenerated|Select TimeGenerated,SourceName,EventIdentifier,ProductName,Message|Format-Table -Wrap -AutoSize}catch{$_.Exception.ToString()}}
foreach($ln in @('System','Application','Setup')){Evtx $ln $ln}
try{
  $pat='StorageSense|AppXDeployment|User Profile|WindowsUpdate|Servicing|VSS|Volsnap|DiskDiagnostic|TaskScheduler|Windows Defender|Shell-Core|Store|AppModel|StateRepository'
  Get-WinEvent -ListLog * -ErrorAction SilentlyContinue | Where-Object {$_.LogName -match $pat -and $_.IsEnabled -and $_.RecordCount -gt 0} | Select -Expand LogName -Unique | ForEach-Object {Evtx $_ (($_ -replace '[\\/:*?"<>| ]','_'))}
}catch{}

Step 7 'Servicing logs'
foreach($src in @('C:\Windows\Panther\setupact.log','C:\Windows\Panther\setuperr.log','C:\Windows\Logs\DISM\dism.log','C:\Windows\Logs\CBS\CBS.log','C:\$WINDOWS.~BT\Sources\Panther\setupact.log','C:\$WINDOWS.~BT\Sources\Panther\setuperr.log')){try{if(Test-Path -LiteralPath $src){Get-Content -LiteralPath $src -Tail 5000 -ErrorAction SilentlyContinue | Out-File (Join-Path $logs (($src -replace '[\\/:*?"<>| ]','_')+'.txt')) -Encoding utf8}}catch{}}

Step 8 'Create ZIP'
Save '99_SUMMARY' {
  $c=Get-Volume -DriveLetter C -ErrorAction SilentlyContinue
  "Computer=$env:COMPUTERNAME";"User=$env:USERNAME";"USERPROFILE=$env:USERPROFILE";"DesktopKnownFolder=$([Environment]::GetFolderPath('Desktop'))"
  if($c){"C_Free_GB=$([math]::Round($c.SizeRemaining/1GB,2))";"C_Used_GB=$([math]::Round(($c.Size-$c.SizeRemaining)/1GB,2))"}
  "Desktop_items=$(@(Get-ChildItem (Join-Path $env:USERPROFILE 'Desktop') -Force -ErrorAction SilentlyContinue).Count)"
  "WindowsOld_exists=$(Test-Path 'C:\Windows.old')"
  "WindowsOld_Desktop_items=$(@(Get-ChildItem ("C:\Windows.old\Users\$env:USERNAME\Desktop") -Force -ErrorAction SilentlyContinue).Count)"
  "ProtonDrive_exists=$(Test-Path (Join-Path $env:USERPROFILE 'Proton Drive'))"
  'Disk health:';Get-PhysicalDisk|Select FriendlyName,MediaType,BusType,HealthStatus,OperationalStatus,Size|Format-Table -AutoSize
}
$zip=Join-Path $desktop ("MGS_PC_FORENSICS_FAST_$stamp.zip")
Compress-Archive -Path (Join-Path $out '*') -DestinationPath $zip -CompressionLevel Optimal -Force
Write-Host ''
Write-Host '============================================================' -ForegroundColor Green
Write-Host 'MGS FAST FORENSICS COMPLETE' -ForegroundColor Green
Write-Host "ZIP: $zip" -ForegroundColor Green
Write-Host '============================================================' -ForegroundColor Green
Read-Host 'Press Enter to close'
