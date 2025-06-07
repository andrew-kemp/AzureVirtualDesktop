\\kempyfslstorage.file.core.windows.net\redirections# ================================
# FSLogix Map and Permission Script (UNC path version, robust for Azure Files)
# ================================
# Prompts for drive letter, storage account (prefix or FQDN), shares, and group names.
# Maps to 'profiles' and 'redirections' shares in order, sets NTFS permissions using the UNC path (not mapped drive), then disconnects.

# Prompt for drive letter (default: Z)
$driveLetter = Read-Host "Enter drive letter to use for mapping (default: Z)"
if ([string]::IsNullOrWhiteSpace($driveLetter)) { $driveLetter = "Z" }
$driveLetter = $driveLetter.TrimEnd(":") # remove any trailing colon

# Prompt for storage account (name or FQDN)
$storageInput = Read-Host "Enter storage account name (e.g. mystorageaccount) or full FQDN (e.g. mystorageaccount.file.core.windows.net)"
if ($storageInput -match "^([^.]+)\.file\.core\.windows\.net$") {
    $storagePrefix = $matches[1]
} elseif ($storageInput -notmatch "\.") {
    $storagePrefix = $storageInput
} else {
    Write-Host "Input not recognized. Please enter either the prefix (e.g. mystorageaccount) or full FQDN (e.g. mystorageaccount.file.core.windows.net)." -ForegroundColor Red
    exit 1
}
$storageFQDN = "$storagePrefix.file.core.windows.net"

# Prompt for share names (comma-separated, default: profiles,redirections)
$shareInput = Read-Host "Enter share names (comma separated, default: profiles,redirections)"
if ([string]::IsNullOrWhiteSpace($shareInput)) {
    $shares = @("profiles", "redirections")
} else {
    $shares = $shareInput -split "," | ForEach-Object { $_.Trim() }
}

# Prompt for Admin and User group names
$adminGroup = Read-Host "Enter FSLogix Admin group name (e.g. _User-AVDAdmins)"
if ([string]::IsNullOrWhiteSpace($adminGroup)) {
    Write-Host "You must provide an admin group name." -ForegroundColor Red
    exit 1
}
$userGroup = Read-Host "Enter FSLogix User group name (e.g. _User-AVDUsers)"
if ([string]::IsNullOrWhiteSpace($userGroup)) {
    Write-Host "You must provide a user group name." -ForegroundColor Red
    exit 1
}

Write-Host "`nSummary:"
Write-Host "Drive letter: $driveLetter"
Write-Host "Storage FQDN: $storageFQDN"
Write-Host "Shares: $($shares -join ', ')"
Write-Host "Admin group: $adminGroup"
Write-Host "User group: $userGroup"
$confirm = Read-Host "Proceed (Y/N)?"
if ($confirm -notin @("Y","y")) {
    Write-Host "Cancelled."
    exit 0
}

function Test-Port445AndMountShare {
    param(
        [string]$StorageFQDN,
        [string]$ShareName,
        [string]$DriveLetter
    )
    $drivePath = "\\$StorageFQDN\$ShareName"
    $connectTestResult = Test-NetConnection -ComputerName $StorageFQDN -Port 445
    if ($connectTestResult.TcpTestSucceeded) {
        # Remove existing mapping if present
        if (Get-PSDrive -Name $DriveLetter -ErrorAction SilentlyContinue) {
            Remove-PSDrive -Name $DriveLetter -Force
            Start-Sleep -Seconds 2
        }
        try {
            New-PSDrive -Name $DriveLetter -PSProvider FileSystem -Root $drivePath -Persist -ErrorAction Stop
            Write-Host "Successfully mapped $drivePath to ${DriveLetter}:"
            Start-Sleep -Seconds 5   # Pause to allow mapping to fully initialize

            return $true
        } catch {
            Write-Host ("ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red
            return $false
        }
    } else {
        Write-Host "Unable to reach $StorageFQDN via port 445." -ForegroundColor Red
        return $false
    }
}

function Set-NTFSPermissions {
    param(
        [string]$LocalPathShare,
        [string]$AdminGroup,
        [string]$UserGroup
    )
    try {
        icacls "$LocalPathShare" /inheritance:r | Out-Null
        icacls "$LocalPathShare" /grant:r "CREATOR OWNER:(OI)(CI)(IO)(M)" | Out-Null
        icacls "$LocalPathShare" /grant:r "${AdminGroup}:(OI)(CI)(F)" | Out-Null
        icacls "$LocalPathShare" /grant:r "${UserGroup}:(M)" | Out-Null
        icacls "$LocalPathShare" /remove:g "Authenticated Users" /t /c | Out-Null
        icacls "$LocalPathShare" /remove:g "Users" /t /c | Out-Null
        Write-Host "NTFS permissions set on $LocalPathShare"
        Start-Sleep -Seconds 2  # Pause to let permissions apply
    } catch {
        Write-Host ("Failed to set NTFS permissions on {0}: {1}" -f $LocalPathShare, $_.Exception.Message) -ForegroundColor Red
    }
}

function Disconnect-Share {
    param(
        [string]$DriveLetter
    )
    if (Get-PSDrive -Name $DriveLetter -ErrorAction SilentlyContinue) {
        Remove-PSDrive -Name $DriveLetter -Force
        Write-Host "Disconnected drive $DriveLetter"
        Start-Sleep -Seconds 2  # Pause to ensure disconnection
    }
}

# Process each share in order
foreach ($share in $shares) {
    Write-Host "`n--- Processing share: $share ---"
    $mounted = Test-Port445AndMountShare -StorageFQDN $storageFQDN -ShareName $share -DriveLetter $driveLetter
    $uncPath = "\\$storageFQDN\$share"
    if ($mounted -and (Test-Path $uncPath)) {
        Set-NTFSPermissions -LocalPathShare $uncPath -AdminGroup $adminGroup -UserGroup $userGroup
    } else {
        Write-Host "UNC path $uncPath not accessible. Skipping permissions." -ForegroundColor Red
    }
    Disconnect-Share -DriveLetter $driveLetter
}
Write-Host "`nAll done."