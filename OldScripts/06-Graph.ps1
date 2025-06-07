# 1. User chooses between entering a storage account name or selecting from a list.
# 2. If entering, user provides name (e.g., mystorageaccount) and script finds SPNs starting with "[Storage Account] mystorageaccount"
# 3. If selecting, user picks from a list of [Storage Account] SPNs (display name only)
# 4. Script sets $ExcludedApp (AppId) and $ExcludedObject (ObjectId)
# 5. Excludes $ExcludedApp from all CA policies targeting all apps, skipping "Microsoft-managed" policies

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
    Install-Module Microsoft.Graph -Scope CurrentUser -Force
}
Import-Module Microsoft.Graph -ErrorAction SilentlyContinue

Write-Host "Connecting to Microsoft Graph..."
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess","Directory.Read.All"

Write-Host ""
Write-Host "How do you want to choose the storage account?"
Write-Host "1. Enter the storage account name (e.g. mystorageaccount)"
Write-Host "2. Select the storage account from a list"
$choice = Read-Host "Enter 1 or 2"

if ($choice -eq "1") {
    $enteredName = Read-Host "Enter the storage account name (e.g. mystorageaccount)"
    $filterQuery = "startswith(displayName,'[Storage Account] $enteredName')"
    $storageSPNs = Get-MgServicePrincipal -Filter $filterQuery -All
    if (-not $storageSPNs) {
        Write-Host "No Service Principals found with a display name starting with '[Storage Account] $enteredName'." -ForegroundColor Red
        exit 1
    }
    $selectedSPN = $storageSPNs | Select-Object -First 1
    Write-Host "Auto-selected Service Principal: $($selectedSPN.DisplayName)"
} elseif ($choice -eq "2") {
    $storageSPNs = Get-MgServicePrincipal -Filter "startswith(displayName,'[Storage Account]')" -All
    if (-not $storageSPNs) {
        Write-Host "No Service Principals found with a display name starting with '[Storage Account]'." -ForegroundColor Red
        exit 1
    }
    Write-Host "`nAvailable Storage Service Principals:"
    for ($i = 0; $i -lt $storageSPNs.Count; $i++) {
        Write-Host ("{0}. {1}" -f ($i+1), $storageSPNs[$i].DisplayName)
    }
    $selection = Read-Host "Enter the number of the Service Principal to select"
    if ($selection -notmatch '^\d+$' -or $selection -lt 1 -or $selection -gt $storageSPNs.Count) {
        Write-Host "Invalid selection!" -ForegroundColor Red
        exit 1
    }
    $selectedSPN = $storageSPNs[$selection - 1]
} else {
    Write-Host "Invalid choice!" -ForegroundColor Red
    exit 1
}

$ExcludedApp = $selectedSPN.AppId
$ExcludedObject = $selectedSPN.Id
Write-Host "`nThe variable ExcludedApp (AppId) is set to: $ExcludedApp"
Write-Host "The variable ExcludedObject (ObjectId) is set to: $ExcludedObject"

Write-Host "`nFinding Conditional Access policies that target All cloud apps..."
$allPolicies = Get-MgIdentityConditionalAccessPolicy -All
$allAppsPolicies = $allPolicies | Where-Object {
    $_.Conditions.Applications.IncludeApplications -contains "All"
}

if (-not $allAppsPolicies) {
    Write-Host "No Conditional Access policies found that target all cloud apps." -ForegroundColor Yellow
    exit 1
}
Write-Host "Policies targeting all cloud apps:"
$allAppsPolicies | ForEach-Object { Write-Host "- $($_.DisplayName) (ID: $($_.Id))" }

foreach ($policy in $allAppsPolicies) {
    if ($policy.DisplayName -like '*Microsoft-managed*') {
        Write-Host "Skipping Microsoft-managed policy: $($policy.DisplayName)"
        continue
    }

    $appConds = $policy.Conditions.Applications
    $excludedApps = $appConds.ExcludeApplications

    if ($excludedApps -notcontains $ExcludedApp) {
        $newExcludedApps = $excludedApps + $ExcludedApp

        $applicationsUpdate = @{}
        if ($null -ne $appConds.IncludeApplications -and $appConds.IncludeApplications.Count -gt 0) {
            $applicationsUpdate.IncludeApplications = $appConds.IncludeApplications
        }
        if ($null -ne $newExcludedApps -and $newExcludedApps.Count -gt 0) {
            $applicationsUpdate.ExcludeApplications = $newExcludedApps
        }

        try {
            Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policy.Id -Conditions @{
                Applications = $applicationsUpdate
            }
            Write-Host "Updated policy $($policy.DisplayName) to exclude AppId $ExcludedApp"
        } catch {
            Write-Host "Failed to update policy $($policy.DisplayName): $_"
        }
    } else {
        Write-Host "Policy $($policy.DisplayName) already excludes AppId $ExcludedApp"
    }
}

Write-Host "`n--- Complete ---"
Write-Host "Please verify the exclusions in the Entra Portal."