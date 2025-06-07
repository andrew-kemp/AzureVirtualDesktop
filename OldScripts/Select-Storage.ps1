# Select-And-Exclude-StorageSPN.ps1
# 1. Lists all [Storage ...] Service Principals in Entra ID with Display Name and AppId.
# 2. Lets user select by number (shows Display Name + AppId).
# 3. Validates and shows full details.
# 4. Adds as exclusion (by ObjectId) to all CA policies targeting all apps.

# Ensure Microsoft Graph module is installed and imported
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
    Install-Module Microsoft.Graph -Scope CurrentUser -Force
}
Import-Module Microsoft.Graph -ErrorAction SilentlyContinue

# Connect to Microsoft Graph
Write-Host "Connecting to Microsoft Graph..."
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess","Directory.Read.All"

# Get all Service Principals whose Display Name starts with '[Storage'
$storageSPNs = Get-MgServicePrincipal -Filter "startswith(displayName,'[Storage')" -All

if (-not $storageSPNs) {
    Write-Host "No Service Principals found with a display name starting with '[Storage'." -ForegroundColor Red
    exit 1
}

Write-Host "`nAvailable [Storage ...] Service Principals:"
for ($i = 0; $i -lt $storageSPNs.Count; $i++) {
    Write-Host "$($i+1). $($storageSPNs[$i].DisplayName) | AppId: $($storageSPNs[$i].AppId) | ObjectId: $($storageSPNs[$i].Id)"
}

$selection = Read-Host "Enter the number of the Service Principal to select"
if ($selection -notmatch '^\d+$' -or $selection -lt 1 -or $selection -gt $storageSPNs.Count) {
    Write-Host "Invalid selection!" -ForegroundColor Red
    exit 1
}

$selectedSPN = $storageSPNs[$selection - 1]

# --- Validate and show details ---
try {
    $validatedSpn = Get-MgServicePrincipal -ServicePrincipalId $selectedSPN.Id
    if (-not $validatedSpn) { throw "Not found" }
} catch {
    Write-Host "`nNo Service Principal found for Object ID: $($selectedSPN.Id)" -ForegroundColor Red
    Write-Host "Please check the Object ID and try again."
    exit 1
}

Write-Host "`n--- Service Principal Details ---"
Write-Host "Display Name         : $($validatedSpn.DisplayName)"
Write-Host "Object ID            : $($validatedSpn.Id)"
Write-Host "App ID               : $($validatedSpn.AppId)"
Write-Host "Application Type     : $($validatedSpn.ServicePrincipalType)"
Write-Host "Account Enabled      : $($validatedSpn.AccountEnabled)"
Write-Host "Created Date         : $($validatedSpn.CreatedDateTime)"
Write-Host "Publisher Name       : $($validatedSpn.PublisherName)"
Write-Host "App Roles            : $($validatedSpn.AppRoles.Count) roles"
Write-Host "`nThis Service Principal is valid and can be used for Conditional Access exclusions."

# --- Find CA policies targeting all cloud apps ---
Write-Host "`nFinding Conditional Access policies that target All cloud apps..."
$allPolicies = Get-MgIdentityConditionalAccessPolicy
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
    $appConds = $policy.Conditions.Applications
    # Only update if neither 'IncludeUserActions' nor 'IncludeAuthenticationContextClassReferences' are set
    if (-not $appConds.IncludeUserActions -and -not $appConds.IncludeAuthenticationContextClassReferences) {
        $excludedApps = $appConds.ExcludeApplications
        if ($excludedApps -notcontains $validatedSpn.Id) {
            $newExcludedApps = $excludedApps + $validatedSpn.Id

            # Dynamically build Applications object: only include non-null/non-empty arrays
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
                Write-Host "Updated policy $($policy.DisplayName) to exclude $($validatedSpn.DisplayName)"
            } catch {
                Write-Host "Failed to update policy $($policy.DisplayName): $_"
            }
        } else {
            Write-Host "Policy $($policy.DisplayName) already excludes $($validatedSpn.DisplayName)"
        }
    } else {
        Write-Host "Policy $($policy.DisplayName) targets User Actions or Authentication Context and cannot be updated for ExcludeApplications."
    }
}

Write-Host "`n--- Complete ---"
Write-Host "Please verify the exclusions in the Entra Portal."