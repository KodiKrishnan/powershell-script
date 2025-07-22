#Author : Kodi Arasan M
#date : 21-July-2023

# === CONFIGURATION ===
$BackupPath       = "C:\Database-bak"
$MariaDBDump      = "C:\Program Files\MariaDB 11.1\bin\mariadb-dump.exe"
$SevenZip         = "C:\Program Files\7-Zip\7z.exe"
$DatabaseName     = "db-name"
$DbUser           = "root"
$DbPassword       = "password`$2025"  # Escape `$`
$RetentionDays    = 7
$Timestamp        = Get-Date -Format "yyyyMMdd"

$SqlFilename      = "$DatabaseName" + "_$Timestamp.sql"
$ZipFilename      = "$DatabaseName" + "_$Timestamp.zip"
$SqlFile          = Join-Path $BackupPath $SqlFilename
$ZipFile          = Join-Path $BackupPath $ZipFilename
$LogFile          = Join-Path $BackupPath "mariadb_backup_log.txt"

# === Ensure Backup Path Exists ===
if (!(Test-Path $BackupPath)) {
    New-Item -ItemType Directory -Path $BackupPath | Out-Null
}

# === Logging Start ===
"`n==================================" | Out-File -Append $LogFile
"Backup started at $(Get-Date)"        | Out-File -Append $LogFile
"SQL file path: $SqlFile"              | Out-File -Append $LogFile

# === Run mariadb-dump ===
"Running database dump..." | Out-File -Append $LogFile
& "$MariaDBDump" --user=$DbUser --password=$DbPassword --single-transaction --routines --databases $DatabaseName --result-file="$SqlFile"

Start-Sleep -Seconds 2

if (!(Test-Path $SqlFile) -or ((Get-Item $SqlFile).Length -eq 0)) {
    "[ERROR] SQL dump failed. File not created or is empty." | Out-File -Append $LogFile
    Write-Host "`n? Dump failed. Check log at $LogFile"
    pause
    exit 1
}

# === Compress SQL File ===
"Compressing SQL using 7-Zip..." | Out-File -Append $LogFile
& "$SevenZip" a -tzip "$ZipFile" "$SqlFile"

Start-Sleep -Seconds 2

if (!(Test-Path $ZipFile)) {
    "[ERROR] Compression failed! ZIP not created." | Out-File -Append $LogFile
    Write-Host "`n? Compression failed. Check log at $LogFile"
    pause
    exit 1
}

# === Delete SQL File After Compression ===
Remove-Item $SqlFile -Force
"Removed SQL file: $SqlFile" | Out-File -Append $LogFile

# === Upload ZIP to S3 ===
"Uploading ZIP to S3..." | Out-File -Append $LogFile

$S3BucketPath = "s3://bucket-name/"
$S3UploadCmd = "aws s3 cp `"$ZipFile`" `"$S3BucketPath`""

Invoke-Expression $S3UploadCmd

if ($LASTEXITCODE -ne 0) {
    "[ERROR] Failed to upload to S3!" | Out-File -Append $LogFile
    Write-Host "`n? S3 upload failed. Check log at $LogFile"
    pause
    exit 1
}

"Uploaded to S3: $S3BucketPath$ZipFilename" | Out-File -Append $LogFile


# === Cleanup Old Backups ===
"Cleaning up backups older than $RetentionDays days..." | Out-File -Append $LogFile
Get-ChildItem -Path $BackupPath -Filter "*.zip" |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$RetentionDays) } |
    ForEach-Object {
        Remove-Item $_.FullName -Force
        "Deleted: $($_.FullName)" | Out-File -Append $LogFile
    }

# === Success ===
"? Backup completed successfully at $(Get-Date)" | Out-File -Append $LogFile
"Backup ZIP: $ZipFile" | Out-File -Append $LogFile
Write-Host "`n? Backup complete: $ZipFile"
