$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$incidentStart = [datetime]'2026-08-15T23:30:00'
$incidentEnd   = [datetime]'2026-08-16T02:30:00'
$outFile = if (Test-Path 'D:\') { 'D:\MGS_PC_TRUTH_SERUM.txt' } else { Join-Path $env:USERPROFILE 'Desktop\MGS_PC_TRUTH_SERUM.txt' }

$lines = New-Object System.Collections.Generic.List[string]
function Add-Line([string]$s='') { $lines.Add($s); Write-Host $s }
function Add-Section([string]$s) { Add-Line ''; Add-Line ('=' * 70); Add-Line $s; Add-Line ('=' * 70) }
function Parse-DuCsv($raw) {
    if (-not $raw) { return @() }
    $start = -1
    for ($i = 0; $i -lt $raw.Count; $i++) {
        if ([string]$raw[$i] -match '^Path,CurrentFileCount,CurrentFileSize,FileCount,DirectoryCount,DirectorySize,DirectorySizeOnDisk') { $start = $i; break }
    }
    if ($start -lt 0) { return @() }
    return @($raw[$start..($raw.Count-1)] | ConvertFrom-Csv)
}
function Show-DuTop([string]$path,[int]$depth=1,[int]$top=20) {
    $raw = & $script:duPath -accepteula -nobanner -c -l $depth $path 2>$null
    $rows = Parse-DuCsv $raw
    if (-not $rows) { Add-Line "DU returned no parseable data for $path"; return }
    $sorted = $rows | Sort-Object { [int64]$_.DirectorySizeOnDisk } -Descending | Select-Object -First $top
    foreach ($r in $sorted) {
        $gb = [math]::Round(([int64]$r.DirectorySizeOnDisk / 1GB), 2)
        $logical = [math]::Round(([int64]$r.DirectorySize / 1GB), 2)
        Add-Line ("{0,9:N2} GB on disk | {1,9:N2} GB logical | {2}" -f $gb,$logical,$r.Path)
    }
}

Add-Section 'MGS PC TRUTH SERUM - READ ONLY'
Add-Line ("Run time: {0}" -f (Get-Date))
Add-Line ("Computer: {0}   User: {1}" -f $env:COMPUTERNAME,$env:USERNAME)
Add-Line 'This script does not delete, move, repair, reinstall, restart, or change sync state.'

Add-Section '1. ACTUAL C: CAPACITY'
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
if ($disk) {
    Add-Line ("C: total     {0:N2} GB" -f ($disk.Size/1GB))
    Add-Line ("C: used      {0:N2} GB" -f (($disk.Size-$disk.FreeSpace)/1GB))
    Add-Line ("C: free      {0:N2} GB" -f ($disk.FreeSpace/1GB))
    Add-Line ("C: free pct  {0:N1}%" -f (($disk.FreeSpace/$disk.Size)*100))
}

Add-Section '2. TOP PHYSICAL DISK CONSUMERS'
$duDir = Join-Path $env:TEMP 'MGS_DU'
$duZip = Join-Path $env:TEMP 'MGS_DU.zip'
$script:duPath = Join-Path $duDir 'du64.exe'
try {
    if (-not (Test-Path $script:duPath)) {
        New-Item -ItemType Directory -Force -Path $duDir | Out-Null
        Invoke-WebRequest 'https://download.sysinternals.com/files/DU.zip' -OutFile $duZip -UseBasicParsing
        Expand-Archive -LiteralPath $duZip -DestinationPath $duDir -Force
    }
    Add-Line 'Top-level C: by PHYSICAL bytes:'
    Show-DuTop 'C:\' 1 25
    Add-Line ''
    Add-Line 'C:\Users\mgste by PHYSICAL bytes:'
    Show-DuTop 'C:\Users\mgste' 1 25
} catch {
    Add-Line ("DU ERROR: {0}" -f $_.Exception.Message)
}

Add-Section '3. OLD WINDOWS REBOOT / UPDATE / BUGCHECK TIMELINE'
$oldLogs = 'C:\Windows.old\Windows\System32\winevt\Logs'
$sys = Join-Path $oldLogs 'System.evtx'
if (Test-Path $sys) {
    $events = Get-WinEvent -FilterHashtable @{Path=$sys; StartTime=$incidentStart; EndTime=$incidentEnd; Id=@(13,19,41,1001,1074,6008,6009,7045)} | Sort-Object TimeCreated
    foreach ($e in $events) {
        Add-Line ("[{0:yyyy-MM-dd HH:mm:ss}] ID {1} {2} / {3}" -f $e.TimeCreated,$e.Id,$e.ProviderName,$e.LevelDisplayName)
        $msg = ($e.Message -replace '\r?\n',' | ')
        if ($msg.Length -gt 1200) { $msg = $msg.Substring(0,1200) + ' ...' }
        Add-Line $msg
        Add-Line ''
    }
} else { Add-Line 'Old System.evtx not found.' }

Add-Section '4. OLD TASK-SCHEDULER ACTIVITY AROUND INCIDENT'
$taskLog = Join-Path $oldLogs 'Microsoft-Windows-TaskScheduler%4Operational.evtx'
if (Test-Path $taskLog) {
    $taskEvents = Get-WinEvent -FilterHashtable @{Path=$taskLog; StartTime=$incidentStart; EndTime=$incidentEnd} |
        Where-Object { $_.LevelDisplayName -in @('Error','Warning') -or $_.Message -match '(?i)MGS|Proton|VistaPrint|Cloudflared|GroupMe|Dominican|PowerShell|cmd\.exe|shutdown|restart|reboot' } |
        Sort-Object TimeCreated
    foreach ($e in $taskEvents) {
        Add-Line ("[{0:yyyy-MM-dd HH:mm:ss}] ID {1} {2}" -f $e.TimeCreated,$e.Id,$e.LevelDisplayName)
        $msg = ($e.Message -replace '\r?\n',' | ')
        if ($msg.Length -gt 1200) { $msg = $msg.Substring(0,1200) + ' ...' }
        Add-Line $msg
        Add-Line ''
    }
} else { Add-Line 'Old TaskScheduler operational log not found.' }

Add-Section '5. OLD APPLICATION FAILURES AROUND INCIDENT'
$app = Join-Path $oldLogs 'Application.evtx'
if (Test-Path $app) {
    $appEvents = Get-WinEvent -FilterHashtable @{Path=$app; StartTime=$incidentStart; EndTime=$incidentEnd; Level=@(1,2,3)} |
        Where-Object { $_.ProviderName -match '(?i)Application Error|Windows Error Reporting|SideBySide|\.NET Runtime|MsiInstaller' -or $_.Message -match '(?i)Proton|Chrome|Brave|Explorer|SideBySide|config\.json|missing|not found' } |
        Sort-Object TimeCreated | Select-Object -First 80
    foreach ($e in $appEvents) {
        Add-Line ("[{0:yyyy-MM-dd HH:mm:ss}] ID {1} {2} / {3}" -f $e.TimeCreated,$e.Id,$e.ProviderName,$e.LevelDisplayName)
        $msg = ($e.Message -replace '\r?\n',' | ')
        if ($msg.Length -gt 1200) { $msg = $msg.Substring(0,1200) + ' ...' }
        Add-Line $msg
        Add-Line ''
    }
} else { Add-Line 'Old Application.evtx not found.' }

Add-Section '6. CURRENT KNOWN-FOLDER TARGETS'
try {
    $k = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    foreach ($name in @('Desktop','Personal','My Pictures','My Music','My Video','{374DE290-123F-4565-9164-39C4925E467B}')) {
        if ($null -ne $k.$name) { Add-Line ("{0} = {1}" -f $name,$k.$name) }
    }
} catch {}

Add-Section '7. OUTPUT'
Add-Line ("Saved copy: {0}" -f $outFile)
Add-Line 'Send a photo of sections 2 and 3 first. Those two sections usually answer the fastest questions.'

$lines | Set-Content -LiteralPath $outFile -Encoding UTF8
