$ErrorActionPreference='Continue'
$ProgressPreference='SilentlyContinue'

$stamp=Get-Date -Format 'yyyyMMdd_HHmmss'
$desktop=[Environment]::GetFolderPath('Desktop')
if(-not $desktop){$desktop=Join-Path $env:USERPROFILE 'Desktop'}
$out=Join-Path $desktop ("MGS_PC_FORENSICS_EXECUTION_$stamp")
$raw=Join-Path $out 'RawEventLogs'
$tasksDir=Join-Path $out 'Tasks'
$scriptsDir=Join-Path $out 'ReferencedScripts'
$logsDir=Join-Path $out 'MGSLogs'
New-Item -ItemType Directory -Force -Path $out,$raw,$tasksDir,$scriptsDir,$logsDir | Out-Null
$err=Join-Path $out 'ERRORS.txt'
$start=[datetime]'2026-08-15T18:00:00'
$end=[datetime]'2026-08-16T00:53:30'

function Step($n,$msg){Write-Host "[$n] $msg" -ForegroundColor Cyan}
function Redact([string]$s){
  if($null -eq $s){return $null}
  $x=$s
  $x=$x -replace '(?i)(gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]{12,})','[REDACTED_TOKEN]'
  $x=$x -replace '(?i)(token|secret|password|passwd|apikey|api_key)\s*[:=]\s*[^ ;,"''\r\n]+','$1=[REDACTED]'
  return $x
}
function SaveText($name,[scriptblock]$body){
  try{& $body 2>&1 | Out-String -Width 10000 | Out-File (Join-Path $out ($name+'.txt')) -Encoding utf8}catch{$_ | Out-File $err -Append -Encoding utf8}
}
function ExportEvtxWindow($src,$label,$ids=$null){
  if(-not (Test-Path -LiteralPath $src)){"MISSING EVTX: $src" | Out-File $err -Append -Encoding utf8; return}
  try{
    $safe=($label -replace '[\\/:*?"<>| ]','_')
    Copy-Item -LiteralPath $src -Destination (Join-Path $raw ($safe+'.evtx')) -Force -ErrorAction SilentlyContinue
    $fh=@{Path=$src;StartTime=$start;EndTime=$end}
    if($ids){$fh.Id=$ids}
    $ev=Get-WinEvent -FilterHashtable $fh -ErrorAction Stop | Select TimeCreated,Id,LevelDisplayName,ProviderName,MachineName,Message
    $ev | Sort-Object TimeCreated | Export-Csv (Join-Path $out ($safe+'_WINDOW.csv')) -NoTypeInformation -Encoding UTF8
    $ev | Sort-Object TimeCreated | Format-List * | Out-String -Width 10000 | Out-File (Join-Path $out ($safe+'_WINDOW.txt')) -Encoding utf8
  }catch{"$label :: $($_.Exception.Message)" | Out-File $err -Append -Encoding utf8}
}
function CopyRedactedText($src,$destName){
  if(-not (Test-Path -LiteralPath $src)){return}
  try{
    $item=Get-Item -LiteralPath $src -Force
    if($item.Length -gt 20MB){"SKIPPED >20MB: $src" | Out-File $err -Append -Encoding utf8; return}
    Get-Content -LiteralPath $src -ErrorAction Stop | ForEach-Object {Redact $_} | Out-File (Join-Path $logsDir $destName) -Encoding utf8
  }catch{"$src :: $($_.Exception.Message)" | Out-File $err -Append -Encoding utf8}
}
function SafeName($s){return ($s -replace '[\\/:*?"<>| ]','_')}

Step 1 'Collect old Security, PowerShell and Sysmon execution evidence'
$oldLog='C:\Windows.old\Windows\System32\winevt\Logs'
ExportEvtxWindow (Join-Path $oldLog 'Security.evtx') 'OLD_Security_4688' @(4688)
ExportEvtxWindow (Join-Path $oldLog 'Microsoft-Windows-PowerShell%4Operational.evtx') 'OLD_PowerShell_Operational'
ExportEvtxWindow (Join-Path $oldLog 'Windows PowerShell.evtx') 'OLD_Windows_PowerShell'
ExportEvtxWindow (Join-Path $oldLog 'Microsoft-Windows-Sysmon%4Operational.evtx') 'OLD_Sysmon_Operational'

Step 2 'Collect current preserved MGS audit and runtime logs'
$logCandidates=@(
 'C:\ProgramData\MGS-MCP\powershell-audit.log',
 'C:\ProgramData\MGS-MCP\vistaprint-cutover.log',
 'C:\ProgramData\MGS-MCP\server.error.log',
 'C:\ProgramData\MGS-MCP\server.log',
 'C:\ProgramData\MGS-MCP\restart-mgs-mcp.ps1',
 'C:\ProgramData\MGS-MCP\run-server.cmd',
 'C:\ProgramData\MGS-MCP\vistaprint-cutover.ps1'
)
foreach($p in $logCandidates){CopyRedactedText $p ((SafeName $p)+'.txt')}
SaveText 'MGS_RECENT_TEXT_FILES' {
  $root='C:\ProgramData\MGS-MCP'
  if(Test-Path $root){
    Get-ChildItem $root -Recurse -File -Force -ErrorAction SilentlyContinue |
      Where-Object {$_.LastWriteTime -ge [datetime]'2026-08-15T18:00:00' -and $_.Length -le 20MB} |
      Select FullName,Length,CreationTime,LastWriteTime,Attributes |
      Sort LastWriteTime | Format-Table -AutoSize
  }
}

Step 3 'Export all MGS, Proton and related scheduled task definitions and referenced scripts'
$interesting='MGS|Proton|Dominican|GroupMe|Telnyx|ICS|Browser Controller|Cloudflared|VistaPrint'
$tasks=Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {($_.TaskName+' '+$_.TaskPath) -match $interesting}
$taskRows=@()
foreach($t in $tasks){
  try{$info=Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue}catch{$info=$null}
  foreach($a in @($t.Actions)){
    $taskRows += [pscustomobject]@{
      TaskPath=$t.TaskPath;TaskName=$t.TaskName;State=$t.State;LastRunTime=if($info){$info.LastRunTime}else{$null};LastTaskResult=if($info){$info.LastTaskResult}else{$null};Execute=$a.Execute;Arguments=(Redact $a.Arguments);WorkingDirectory=$a.WorkingDirectory
    }
    $candidate=$null
    $args=[string]$a.Arguments
    if($args -match '(?i)-File\s+["'']?([^"'']+?\.(?:ps1|psm1|cmd|bat))(?:["'']|\s|$)'){$candidate=$matches[1]}
    elseif(([string]$a.Execute) -match '(?i)\.(ps1|psm1|cmd|bat)$'){$candidate=[string]$a.Execute}
    if($candidate -and (Test-Path -LiteralPath $candidate)){
      try{Get-Content -LiteralPath $candidate -ErrorAction Stop | ForEach-Object {Redact $_} | Out-File (Join-Path $scriptsDir ((SafeName ($t.TaskPath+$t.TaskName))+'__'+(Split-Path $candidate -Leaf)+'.txt')) -Encoding utf8}catch{}
    }
  }
  try{Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath | Out-File (Join-Path $tasksDir ((SafeName ($t.TaskPath+$t.TaskName))+'.xml')) -Encoding utf8}catch{}
}
$taskRows | Sort TaskPath,TaskName | Export-Csv (Join-Path $out 'INTERESTING_TASK_ACTIONS.csv') -NoTypeInformation -Encoding UTF8

Step 4 'Extract task executions and failures from the old Task Scheduler log'
$oldTask=Join-Path $oldLog 'Microsoft-Windows-TaskScheduler%4Operational.evtx'
if(Test-Path $oldTask){
  try{
    $ev=Get-WinEvent -FilterHashtable @{Path=$oldTask;StartTime=$start;EndTime=$end} -ErrorAction Stop |
      Where-Object {$_.Message -match $interesting -or $_.LevelDisplayName -in @('Error','Warning')} |
      Select TimeCreated,Id,LevelDisplayName,ProviderName,Message
    $ev | Sort TimeCreated | Export-Csv (Join-Path $out 'OLD_TASKS_RELEVANT_WINDOW.csv') -NoTypeInformation -Encoding UTF8
  }catch{$_ | Out-File $err -Append -Encoding utf8}
}

Step 5 'Inspect Recycle Bin deletion metadata'
$recycleRows=@()
try{
  Get-ChildItem 'C:\$Recycle.Bin' -Force -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    $f=$_
    $original=$null;$deleted=$null;$origSize=$null;$parse=''
    if($f.Name -like '$I*'){
      try{
        $b=[IO.File]::ReadAllBytes($f.FullName)
        if($b.Length -ge 24){
          $origSize=[BitConverter]::ToInt64($b,8)
          $ft=[BitConverter]::ToInt64($b,16)
          if($ft -gt 0){$deleted=[DateTime]::FromFileTimeUtc($ft).ToLocalTime()}
          if($b.Length -ge 28){
            $charCount=[BitConverter]::ToInt32($b,24)
            if($charCount -gt 0 -and (28+($charCount*2)) -le ($b.Length+2)){$original=[Text.Encoding]::Unicode.GetString($b,28,[Math]::Min($charCount*2,$b.Length-28)).Trim([char]0)}
            elseif($b.Length -gt 24){$original=[Text.Encoding]::Unicode.GetString($b,24,$b.Length-24).Trim([char]0)}
          }
          $parse='parsed'
        }
      }catch{$parse=$_.Exception.Message}
    }
    $recycleRows += [pscustomobject]@{RecyclePath=$f.FullName;Name=$f.Name;Length=$f.Length;CreationTime=$f.CreationTime;LastWriteTime=$f.LastWriteTime;OriginalPath=$original;OriginalSize=$origSize;DeletedLocalTime=$deleted;Parse=$parse}
  }
}catch{$_ | Out-File $err -Append -Encoding utf8}
$recycleRows | Sort DeletedLocalTime,LastWriteTime | Export-Csv (Join-Path $out 'RECYCLE_BIN_METADATA.csv') -NoTypeInformation -Encoding UTF8

Step 6 'Inventory shadow copies and restore-capable snapshots'
SaveText 'SHADOW_COPIES' {
  & vssadmin.exe list shadows 2>&1
  ''
  Get-CimInstance Win32_ShadowCopy -ErrorAction SilentlyContinue | Select ID,InstallDate,DeviceObject,VolumeName,OriginatingMachine,ServiceMachine,State,Persistent,ClientAccessible | Format-List
}

Step 7 'Capture key path state and timestamps'
SaveText 'KEY_PATH_STATE' {
  $paths=@(
    'C:\Users\mgste\Desktop',
    'C:\Windows.old\Users\mgste\Desktop',
    'C:\ProgramData\Microsoft\Windows\AppRepository',
    'C:\Program Files\Google\Chrome\Application',
    'C:\Program Files\BraveSoftware\Brave-Browser\Application',
    'C:\Program Files (x86)\Google\GoogleUpdater',
    'C:\Program Files (x86)\BraveSoftware\Update',
    'C:\Program Files (x86)\Microsoft\EdgeUpdate',
    'C:\ProgramData\MGS-MCP'
  )
  foreach($p in $paths){
    "### $p"
    if(Test-Path -LiteralPath $p){
      Get-Item -LiteralPath $p -Force | Select FullName,CreationTime,LastWriteTime,Attributes,LinkType,Target | Format-List
      Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | Select Name,FullName,Length,CreationTime,LastWriteTime,Attributes | Sort LastWriteTime | Format-Table -AutoSize
    }else{"MISSING"}
    ''
  }
}

Step 8 'Query Defender detections and exclusions without changing anything'
SaveText 'DEFENDER_STATE' {
  try{Get-MpThreatDetection -ErrorAction SilentlyContinue | Format-List *}catch{}
  try{Get-MpPreference -ErrorAction SilentlyContinue | Select ExclusionPath,ExclusionProcess,ExclusionExtension,ControlledFolderAccessProtectedFolders,EnableControlledFolderAccess | Format-List}catch{}
}

Step 9 'Create ZIP'
SaveText '00_EXECUTION_SUMMARY' {
  "Window: $start through $end"
  "Computer=$env:COMPUTERNAME User=$env:USERNAME Profile=$env:USERPROFILE"
  "Old Security present=$(Test-Path (Join-Path $oldLog 'Security.evtx'))"
  "Old PowerShell Operational present=$(Test-Path (Join-Path $oldLog 'Microsoft-Windows-PowerShell%4Operational.evtx'))"
  "Old Windows PowerShell present=$(Test-Path (Join-Path $oldLog 'Windows PowerShell.evtx'))"
  "Old Sysmon present=$(Test-Path (Join-Path $oldLog 'Microsoft-Windows-Sysmon%4Operational.evtx'))"
}
$zip=Join-Path $desktop ("MGS_PC_FORENSICS_EXECUTION_$stamp.zip")
Compress-Archive -Path (Join-Path $out '*') -DestinationPath $zip -CompressionLevel Optimal -Force
Write-Host ''
Write-Host '============================================================' -ForegroundColor Green
Write-Host 'MGS EXECUTION EVIDENCE COLLECTION COMPLETE' -ForegroundColor Green
Write-Host ("ZIP: {0}" -f $zip) -ForegroundColor Green
Write-Host '============================================================' -ForegroundColor Green
Read-Host 'Press Enter to close'
