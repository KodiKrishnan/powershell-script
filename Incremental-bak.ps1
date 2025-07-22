#Author : Kodi Arasan M
#date : 21-July-2023

# ========== Configuration ==========
$BackupDir = "C:\Database-bak\incremental"
$MariaClient = "C:\Program Files\MariaDB 11.1\bin\mysql.exe"
$DbUser = "root"
$DbPassword = "password`$2025"
$LogFile = "$BackupDir\incremental_backup.log"
$BinlogDir = "C:\Program Files\MariaDB 11.1\data"
$LastPosFile = "$BackupDir\last_position.txt"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$ZipFile = "$BackupDir\binlogs_$Timestamp.zip"

$S3BucketPath = "s3://bucketname/incremental/"
$S3UploadCmd = "aws s3 cp `"$ZipFile`" `"$S3BucketPath`""

# ========== Ensure Backup Directory ==========
if (!(Test-Path $BackupDir)) {
    New-Item -ItemType Directory -Path $BackupDir | Out-Null
}

# ========== Logging ==========
function Log {
    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $msg = "$time - $($args -join ' ')"
    Write-Output $msg
    Add-Content -Path $LogFile -Value $msg
}

Log "=================================="
Log "Incremental Backup started at $(Get-Date)"

# ========== Get Binary Logs ==========
try {
    $RawOutput = & "$MariaClient" "-u$DbUser" "-p$DbPassword" "-e" "SHOW BINARY LOGS;" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Log "[ERROR] Failed to retrieve binary logs:"
        Log "$RawOutput"
        exit 1
    }

    $ParsedLogs = $RawOutput | Select-String "^gbeassist_master-bin" | ForEach-Object {
        ($_ -split "\s+")[0]
    }

    if ($ParsedLogs.Count -eq 0) {
        Log "[ERROR] No binary logs found!"
        exit 1
    }

    Log "Parsed Binlogs:"
    $ParsedLogs | ForEach-Object { Log $_ }

    # ========== Determine Last Backed-Up Log ==========
    $LastLog = ""
    if (Test-Path $LastPosFile) {
        $LastLog = Get-Content $LastPosFile
    }

    $LogsToBackup = if ($LastLog) {
        $Index = $ParsedLogs.IndexOf($LastLog)
        if ($Index -lt 0) { $ParsedLogs } else { $ParsedLogs[($Index + 1)..($ParsedLogs.Count - 1)] }
    } else {
        $ParsedLogs
    }

    if ($LogsToBackup.Count -eq 0) {
        Log "No new binlogs to back up."
        exit 0
    }

    # ========== Backup and Track Logs ==========
    $CopiedFiles = @()
    foreach ($log in $LogsToBackup) {
        $src = Join-Path $BinlogDir $log
        $dst = Join-Path $BackupDir $log
        if (Test-Path $src) {
            Copy-Item $src $dst -Force
            Log "Copied $log"
            Set-Content $LastPosFile $log
            $CopiedFiles += $dst
        } else {
            Log "[WARNING] Binlog $log not found at $src"
        }
    }

    # ========== Compress Copied Logs ==========
    if ($CopiedFiles.Count -gt 0) {
        Compress-Archive -Path $CopiedFiles -DestinationPath $ZipFile -Force
        Log "Compressed binlogs into $ZipFile"

        # ========== Remove Uncompressed Files ==========
        foreach ($file in $CopiedFiles) {
            Remove-Item $file -Force
            Log "Removed original file $file"
        }
    }

    # ========== Upload to S3 ==========
    $uploadResult = Invoke-Expression $S3UploadCmd
    Log "Uploaded $ZipFile to S3 path $S3BucketPath"

    # ========== Cleanup Old Local Backups (older than 7 days) ==========
    $OldFiles = Get-ChildItem -Path $BackupDir -Filter "*.zip" | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) }
    foreach ($file in $OldFiles) {
        Remove-Item $file.FullName -Force
        Log "Deleted old backup: $($file.FullName)"
    }

    Log "Incremental backup completed successfully."
} catch {
    Log "[EXCEPTION] $_"
    exit 1
}
