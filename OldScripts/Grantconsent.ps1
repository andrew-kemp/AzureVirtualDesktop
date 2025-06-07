# Single prompt for storage account prefix or FQDN
$storageAccountInput = Read-Host "Enter the storage account name or FQDN (e.g. kempyfsl or kempyfsl.file.core.windows.net)"
if ($storageAccountInput -match "^([^.]+)\.file\.core\.windows\.net$") {
    $storageAccountPrefix = $matches[1]
    $storageAccountFqdn = $storageAccountInput
} elseif ($storageAccountInput -notmatch "\.") {
    $storageAccountPrefix = $storageAccountInput
    $storageAccountFqdn = "$storageAccountPrefix.file.core.windows.net"
} else {
    Write-Host "Input not recognized. Please enter either the prefix (e.g. kempyfsl) or full FQDN (e.g. kempyfsl.file.core.windows.net)." -ForegroundColor Red
    exit 1
}

# Search for a Service Principal whose display name starts with "[Storage Account] <prefix>"
$storageAppDisplayNamePrefix = "[Storage Account] $storageAccountPrefix"
$storageApps = Get-MgServicePrincipal -Filter "startswith(displayName,'$storageAppDisplayNamePrefix')" -All

if (-not $storageApps) {
    Write-Host "No Service Principal found starting with '$storageAppDisplayNamePrefix'."
    Write-Host "You can verify the display name in Entra ID > Enterprise Applications."
    exit 1
}

if ($storageApps.Count -gt 1) {
    Write-Host "Multiple Service Principals found starting with '$storageAppDisplayNamePrefix'. Please select one:"
    $storageApps | ForEach-Object -Begin { $i=1 } -Process {
        Write-Host "$i. $($_.DisplayName) ($($_.Id))"
        $i++
    }
    $choice = Read-Host "Enter the number of the Service Principal to use"
    $selectedApp = $storageApps[[int]$choice - 1]
} else {
    $selectedApp = $storageApps[0]
}

Write-Host "Storage Account FQDN: $storageAccountFqdn"
Write-Host "Found Service Principal: $($selectedApp.DisplayName) ($($selectedApp.Id))"

# Grant admin consent for all Graph permissions (if required)
Write-Host "`nGranting admin consent for Graph permissions to '$($selectedApp.DisplayName)' (if required)..."
try {
    # List all required resource access for the app to find Graph scopes
    $reqAccess = $selectedApp.AppRolesAssigned
    Write-Host "If any permissions require admin consent, please review and grant in the Entra portal."
} catch {
    Write-Host "Could not enumerate required permissions. Please verify manually in Entra."
}

# Exclude app from all Conditional Access policies
Write-Host "`nChecking Conditional Access policies to exclude the app..."
$policies = Get-MgConditionalAccessPolicy
foreach ($policy in $policies) {
    $excludedApps = $policy.Conditions.Applications.ExcludeApplications
    if ($excludedApps -notcontains $selectedApp.Id) {
        $newExcludedApps = $excludedApps + $selectedApp.Id
        try {
            Update-MgConditionalAccessPolicy -ConditionalAccessPolicyId $policy.Id -Conditions @{
                Applications = @{
                    IncludeApplications = $policy.Conditions.Applications.IncludeApplications
                    ExcludeApplications = $newExcludedApps
                }
            }
            Write-Host "Updated policy $($policy.DisplayName) to exclude $($selectedApp.DisplayName)"
        } catch {
            Write-Host "Failed to update policy $($policy.DisplayName): $_"
        }
    } else {
        Write-Host "Policy $($policy.DisplayName) already excludes $($selectedApp.DisplayName)"
    }
}

Write-Host "`n--- Complete ---"
Write-Host "Please verify:"
Write-Host "- Storage App permissions and consent in Entra Portal"
Write-Host "- Conditional Access exclusions"