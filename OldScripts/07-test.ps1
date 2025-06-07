# 1. User chooses between entering a storage account name or selecting from a list.
# 2. If entering, user provides name (e.g., mystorageaccount) and script finds SPNs starting with "[Storage Account] mystorageaccount"
# 3. If selecting, user picks from a list of [Storage Account] SPNs (display name only)
# 4. Script sets $ExcludedApp (AppId) and $ExcludedObject (ObjectId)
# 5. Excludes $ExcludedApp from all CA policies targeting all apps, skipping "Microsoft-managed" policies
# 6. Ensures Microsoft Graph permissions (openid, profile, User.Read) exist and prompts user to grant admin consent

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
    Install-Module Microsoft.Graph -Scope CurrentUser -Force
}
Import-Module Microsoft.Graph -ErrorAction SilentlyContinue

Write-Host "Connecting to Microsoft Graph..."
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess","Directory.Read.All","Application.ReadWrite.All"

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

# ------------------------------
# Ensure Microsoft Graph delegated permissions: openid, profile, User.Read
# ------------------------------

Write-Host "`nEnsuring delegated Microsoft Graph permissions: openid, profile, User.Read"

# Get the Application object by AppId (not ObjectId)
$appObj = Get-MgApplication -Filter "appId eq '$ExcludedApp'" | Select-Object -First 1
if (-not $appObj) {
    Write-Host "Application object with AppId $ExcludedApp not found." -ForegroundColor Red
    exit 1
}

# Get Microsoft Graph Service Principal and permission scopes
$graphApiSpn = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'" | Select-Object -First 1
$scopeValues = @("openid", "profile", "User.Read")
$scopeObjects = $graphApiSpn.Oauth2PermissionScopes | Where-Object { $scopeValues -contains $_.Value }

# Build ResourceAccess as correct type
$resourceAccess = foreach ($scope in $scopeObjects) {
    $ra = [Microsoft.Graph.PowerShell.Models.MicrosoftGraphResourceAccess]::new()
    $ra.Id = $scope.Id
    $ra.Type = "Scope"
    $ra
}

# Build RequiredResourceAccess as correct type
$existingReqs = @()
if ($appObj.RequiredResourceAccess) {
    $existingReqs = $appObj.RequiredResourceAccess
    # Remove any previous Graph access so we can add it cleanly
    $existingReqs = $existingReqs | Where-Object { $_.ResourceAppId -ne $graphApiSpn.AppId }
}
$requiredResourceAccess = @(
    $existingReqs +
    (New-Object -TypeName Microsoft.Graph.PowerShell.Models.MicrosoftGraphRequiredResourceAccess -Property @{
        ResourceAppId = $graphApiSpn.AppId
        ResourceAccess = $resourceAccess
    })
)

# Update the application with the required permissions
try {
    Update-MgApplication -ApplicationId $appObj.Id -RequiredResourceAccess $requiredResourceAccess
    Write-Host "Application permissions updated."
} catch {
    Write-Host "Failed to update application permissions: $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "---------------------------------------------------------------"
Write-Host "IMPORTANT: Grant Admin Consent in Azure Portal"
Write-Host "Go to: Azure Portal > App registrations > $($appObj.DisplayName) > API permissions > Grant admin consent"
Write-Host "This is required for openid, profile, and User.Read delegated permissions to be effective."
Write-Host "---------------------------------------------------------------"
Write-Host ""
Write-Host "--- Complete ---"
Write-Host "Please verify the CA exclusions and permissions in the Entra Portal."