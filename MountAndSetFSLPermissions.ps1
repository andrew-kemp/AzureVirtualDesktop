# ================================
# Mount FSLogix Shares and Set NTFS Permissions
# ================================
# Prompts for group names, share names, and storage account (prefix or FQDN).
# If share names are omitted, uses defaults: profiles/redirections.

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

# Prompt for storage account prefix or full FQDN
$storageInput = Read-Host "Enter storage account name (e.g. mystorageaccount) or full FQDN (e.g. mystorageaccount.file.core.windows.net)"
# Extract prefix if FQDN provided
if ($storageInput -match "^([^.]+)\.file\.core\.windows\.net$") {
    $storagePrefix = $matches[1]
} elseif ($storageInput -notmatch "\.") {
    $storagePrefix = $storageInput
} else {
    Write-Host "Input not recognized. Please enter either the prefix (e.g. mystorageaccount) or full FQDN (e.g. mystorageaccount.file.core.windows.net)." -ForegroundColor Red
    exit 1
}
$storageFQDN = "$storagePrefix.file.core.windows.net"

# Prompt for share names (comma-separated), default to profiles,redirections
$shareInput = Read-Host "Enter share names (comma separated, default: profiles,redirections)"
if ([string]::IsNullOrWhiteSpace($shareInput)) {
    $shares = @("profiles", "redirections")
} else {
    $shares = $shareInput -split "," | ForEach-Object { $_.Trim() }
}

# Prompt for drive letters (auto-assign: Y, Z, then ask if more than 2)
$defaultDrives = @("Y", "Z")
if ($shares.Count -le 2) {
    $driveLetters = $defaultDrives[0..($shares.Count-1)]
} else {
    $driveLetters = @()
    for ($i = 0; $i -lt $shares.Count; $i++) {
        $letter = Read-Host "Enter drive letter to use for $($shares[$i]) share (default: next available)"
        if ([string]::IsNullOrWhiteSpace($letter)) {
            $letter = [char]( [byte][char]"Y" + $i )
        }
        $driveLetters += $letter
    }
}

Write-Host "`nSummary:"
Write-Host "Admin group: $adminGroup"
Write-Host "User group: $userGroup"
Write-Host "Storage FQDN: $storageFQDN"
Write-Host "Shares to mount: $($shares -join ', ')"
Write-Host "Drive letters: $($driveLetters -join ', ')"
$confirm = Read-Host "Proceed (Y/N)?"
if ($confirm -notin @("Y","y")) {
    Write-Host "Cancelled."
    exit 0
}

# ================================
# FUNCTIONS
# ================================
function Test-Port445AndMountShare {
    param(
        [string]$StorageFQDN,
        [string]$ShareName,
        [string]$DriveLetter
    )
    $connectTestResult = Test-NetConnection -ComputerName $StorageFQDN -Port 445
    if ($connectTestResult.TcpTestSucceeded) {
        # Remove existing mapping if present
        if (Get-PSDrive -Name $DriveLetter -ErrorAction SilentlyContinue) {
            Remove-PSDrive -Name $DriveLetter -Force
        }
        $drivePath = "\\$StorageFQDN\$ShareName"
        try {
            New-PSDrive -Name $DriveLetter -PSProvider FileSystem -Root $drivePath -Persist -ErrorAction Stop
            Write-Host "Successfully mapped $drivePath to ${DriveLetter}:\"
            return "${DriveLetter}:\"
        } catch {
            Write-Error "Failed to map $drivePath to ${DriveLetter}:\ - $_"
            return $null
        }
    } else {
        Write-Error -Message "Unable to reach $StorageFQDN via port 445. Check your firewall or network configuration."
        return $null
    }
}

function Set-NTFSPermissions {
    param(
        [string]$LocalPathShare,
        [string]$AdminGroup,
        [string]$UserGroup
    )
    icacls $LocalPathShare /inheritance:r | Out-Null
    icacls $LocalPathShare /grant:r "CREATOR OWNER:(OI)(CI)(IO)(M)" | Out-Null
    icacls $LocalPathShare /grant:r "${AdminGroup}:(OI)(CI)(F)" | Out-Null
    icacls $LocalPathShare /grant:r "${UserGroup}:(M)" | Out-Null
    icacls $LocalPathShare /remove:g "Authenticated Users" /t /c | Out-Null
    icacls $LocalPathShare /remove:g "Users" /t /c | Out-Null
    Write-Host "NTFS permissions set on $LocalPathShare"
}

# ================================
# MAIN SCRIPT
# ================================
for ($i = 0; $i -lt $shares.Count; $i++) {
    $share = $shares[$i]
    $driveLetter = $driveLetters[$i]
    Write-Host "`n--- Processing share: $share ---"
    $localPath = Test-Port445AndMountShare -StorageFQDN $storageFQDN -ShareName $share -DriveLetter $driveLetter
    if ($localPath) {
        Set-NTFSPermissions -LocalPathShare $localPath -AdminGroup $adminGroup -UserGroup $userGroup
    } else {
        Write-Warning "Skipping permission set for $share as it could not be mounted."
    }
}