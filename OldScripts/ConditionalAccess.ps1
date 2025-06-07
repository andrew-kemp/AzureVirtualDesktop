# Make sure you are logged in with: Connect-MgGraph

# 1. Select Application and store its AppId and ObjectId
$applications = @(Get-MgApplication -Filter "startswith(displayName, '[Storage Account]')" | Select-Object DisplayName, AppId, Id)
if (!$applications -or $applications.Count -eq 0) {
    Write-Host "No applications found."
    exit
}
Write-Host "Select an application:"
for ($i = 0; $i -lt $applications.Count; $i++) {
    Write-Host "$($i+1): $($applications[$i].DisplayName) | AppId: $($applications[$i].AppId) | ObjectId: $($applications[$i].Id)"
}
$selection = Read-Host "`nEnter the number of the application you want to select"
if ($selection -match '^\d+$' -and $selection -ge 1 -and $selection -le $applications.Count) {
    $selectedApp = $applications[$selection - 1]
    $CAExclude = $selectedApp.AppId # <-- This is the correct value to use in CA policy exclusions
    $ObjectId = $selectedApp.Id
    Write-Host "`nYou selected: $($selectedApp.DisplayName)"
    Write-Host "AppId stored in `$CAExclude: $CAExclude"
    Write-Host "ObjectId: $ObjectId"
} else {
    Write-Host "Invalid selection or no application selected."
    exit
}

# 2. Get CA policies that target all apps, excluding 'Microsoft Managed'
$policies = Get-MgIdentityConditionalAccessPolicy
$filteredPolicies = $policies | Where-Object {
    $_.Conditions.Applications.IncludeApplications -contains "All" -and
    $_.DisplayName -notlike "*Microsoft Managed*"
}
Write-Host "`nConditional Access policies targeting ALL apps (excluding 'Microsoft Managed'):"
$filteredPolicies | Select-Object DisplayName, Id, State | Format-Table -AutoSize

# 3. Update each policy to exclude the selected AppId (if not already present)
foreach ($policy in $filteredPolicies) {
    # Double-check policy is not Microsoft-managed
    if ($policy.DisplayName -like "Microsoft-managed*") {
        Write-Host "`nSkipping Microsoft-managed policy '$($policy.DisplayName)' (cannot update excluded apps)."
        continue
    }
    # Ensure ExcludeApplications is always an array
    $excludedApps = @($policy.Conditions.Applications.ExcludeApplications)
    if (-not $excludedApps.Contains($CAExclude)) {
        $newExcludedApps = $excludedApps + $CAExclude

        # Prepare update body: preserve existing include/exclude lists
        $updateBody = @{
            Conditions = @{
                Applications = @{
                    IncludeApplications = $policy.Conditions.Applications.IncludeApplications
                    ExcludeApplications = $newExcludedApps
                }
                # You can add more condition properties here if needed, e.g., Users, ClientAppTypes, etc.
            }
        }

        Write-Host "`nUpdating policy '$($policy.DisplayName)' (Id: $($policy.Id)) to exclude AppId $CAExclude..."
        try {
            Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policy.Id -BodyParameter $updateBody
            Write-Host "Policy '$($policy.DisplayName)' updated."
        } catch {
            Write-Host "Failed to update policy '$($policy.DisplayName)': $($_.Exception.Message)"
        }
    } else {
        Write-Host "`nPolicy '$($policy.DisplayName)' already excludes AppId $CAExclude."
    }
}