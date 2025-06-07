# --- AVD-Phase3.ps1 ---
# All input prompts are at the top. After confirmation, the script runs all actions.

# Function to check if a module is installed
function Install-ModuleIfNotInstalled {
    param ([string]$ModuleName)
    if (-not (Get-Module -ListAvailable -Name $ModuleName)) {
        Install-Module -Name $ModuleName -Scope CurrentUser -Force
    }
}

# Install necessary modules
Install-ModuleIfNotInstalled -ModuleName "Az"
Install-ModuleIfNotInstalled -ModuleName "Az.DesktopVirtualization"
Install-ModuleIfNotInstalled -ModuleName "Microsoft.Graph"
Install-ModuleIfNotInstalled -ModuleName "Microsoft.Graph.Identity.SignIns"
Install-ModuleIfNotInstalled -ModuleName "Microsoft.Graph.Applications"

# ---------------------#
#     USER PROMPTS     #
# ---------------------#

$resourceGroupName = Read-Host -Prompt "Enter the name of the resource group for your AVD hosts"
$prefix = Read-Host -Prompt "Enter a prefix for all group/device names (leave blank to use the resource group name)"
if ([string]::IsNullOrWhiteSpace($prefix)) { $prefix = $resourceGroupName }

$appGroupName = Read-Host -Prompt "Enter the Application Group name (default: ${prefix}-AppGroup)"
if ([string]::IsNullOrWhiteSpace($appGroupName)) { $appGroupName = "${prefix}-AppGroup" }

# Subscription selection (list at top for easier reference)
$subscriptions = Get-AzSubscription
for ($i = 0; $i -lt $subscriptions.Count; $i++) {
    Write-Host "$i. $($subscriptions[$i].Name) - $($subscriptions[$i].Id)"
}
$subscriptionNumber = Read-Host -Prompt "Enter the number of the subscription from the list above"
if (-not ($subscriptionNumber -as [int]) -or $subscriptionNumber -ge $subscriptions.Count) {
    Write-Host "Invalid subscription selection. Exiting."
    exit 1
}
$selectedSubscription = $subscriptions[$subscriptionNumber]
$subscriptionId = $selectedSubscription.Id

$useExistingGroups = Read-Host -Prompt "Do you want to use existing AVD groups? (Y/N)"
if ($useExistingGroups -in @('Y','y')) {
    $userGroupName = Read-Host -Prompt "Enter the name of the existing AVD Users group"
    $adminGroupName = Read-Host -Prompt "Enter the name of the existing AVD Admins group"
    $deviceGroupName = Read-Host -Prompt "Enter the name of the existing AVD Device group"
} else {
    $userGroupName = Read-Host -Prompt "Enter the user group name (default: _User-$prefix-Users)"
    if ([string]::IsNullOrWhiteSpace($userGroupName)) { $userGroupName = "_User-$prefix-Users" }
    $adminGroupName = Read-Host -Prompt "Enter the admin group name (default: _User-$prefix-Admins)"
    if ([string]::IsNullOrWhiteSpace($adminGroupName)) { $adminGroupName = "_User-$prefix-Admins" }
    $deviceGroupName = Read-Host -Prompt "Enter the device group name (default: _Device-$prefix)"
    if ([string]::IsNullOrWhiteSpace($deviceGroupName)) { $deviceGroupName = "_Device-$prefix" }

    $userMailNickname = Read-Host -Prompt "Mail nickname for user group (default: user${prefix}users)"
    if ([string]::IsNullOrWhiteSpace($userMailNickname)) { $userMailNickname = "user${prefix}users" }
    $adminMailNickname = Read-Host -Prompt "Mail nickname for admin group (default: user${prefix}admins)"
    if ([string]::IsNullOrWhiteSpace($adminMailNickname)) { $adminMailNickname = "user${prefix}admins" }
    $deviceMailNickname = Read-Host -Prompt "Mail nickname for device group (default: devices${prefix})"
    if ([string]::IsNullOrWhiteSpace($deviceMailNickname)) { $deviceMailNickname = "devices${prefix}" }
}

$storageAppDisplayName = Read-Host -Prompt "Enter the display name of the Storage App (Enterprise Application)"

# Prompt for storage account name/prefix and build FQDN
$storageAccountInput = Read-Host -Prompt "Enter the storage account name or FQDN (e.g. kempyfsl or kempyfsl.file.core.windows.net)"
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

Write-Host "`nSummary of your choices:"
Write-Host "Resource group: $resourceGroupName"
Write-Host "Prefix: $prefix"
Write-Host "Application Group: $appGroupName"
Write-Host "Subscription: $($selectedSubscription.Name) ($subscriptionId)"
if ($useExistingGroups -in @('Y','y')) {
    Write-Host "User Group: $userGroupName"
    Write-Host "Admin Group: $adminGroupName"
    Write-Host "Device Group: $deviceGroupName"
} else {
    Write-Host "User Group: $userGroupName ($userMailNickname)"
    Write-Host "Admin Group: $adminGroupName ($adminMailNickname)"
    Write-Host "Device Group: $deviceGroupName ($deviceMailNickname)"
}
Write-Host "Storage App Display Name: $storageAppDisplayName"
Write-Host "Storage Account FQDN: $storageAccountFqdn"
$proceed = Read-Host "Proceed with these settings? (Y/N)"
if ($proceed -notin @('Y', 'y')) {
    Write-Host "Exiting."
    exit
}

# ---------------------#
#      AZURE LOGIN     #
# ---------------------#

Write-Host "`nConnecting to Azure and Microsoft Graph..."
Connect-AzAccount
Connect-MgGraph -Scopes "Application.ReadWrite.All", "Directory.ReadWrite.All", "Policy.ReadWrite.ConditionalAccess"
Set-AzContext -SubscriptionId $subscriptionId

# ---------------------#
#   GROUP MANAGEMENT   #
# ---------------------#

if ($useExistingGroups -in @('Y','y')) {
    $userGroupObj = Get-AzADGroup -DisplayName $userGroupName
    if (-not $userGroupObj) { Write-Host "User group '$userGroupName' not found. Exiting."; exit 1 }
    $userGroupId = $userGroupObj.Id

    $adminGroupObj = Get-AzADGroup -DisplayName $adminGroupName
    if (-not $adminGroupObj) { Write-Host "Admin group '$adminGroupName' not found. Exiting."; exit 1 }
    $adminGroupId = $adminGroupObj.Id

    $deviceGroupObj = Get-AzADGroup -DisplayName $deviceGroupName
    if (-not $deviceGroupObj) { Write-Host "Device group '$deviceGroupName' not found. Exiting."; exit 1 }
    $deviceGroupId = $deviceGroupObj.Id
} else {
    $userGroupObj = New-AzADGroup -DisplayName $userGroupName -MailNickname $userMailNickname -SecurityEnabled $true -MailEnabled $false
    $adminGroupObj = New-AzADGroup -DisplayName $adminGroupName -MailNickname $adminMailNickname -SecurityEnabled $true -MailEnabled $false
    $dynamicRule = "(device.displayName -startsWith `"$prefix`")"
    $deviceGroupObj = New-AzADGroup -DisplayName $deviceGroupName -MailNickname $deviceMailNickname -SecurityEnabled $true -MailEnabled $false -GroupTypes "DynamicMembership" -MembershipRule $dynamicRule -MembershipRuleProcessingState "On"
    $userGroupId = $userGroupObj.Id
    $adminGroupId = $adminGroupObj.Id
    $deviceGroupId = $deviceGroupObj.Id
}

# ---------------------#
#    VM AUTO-SHUTDOWN  #
# ---------------------#

$vms = Get-AzVM -ResourceGroupName $resourceGroupName | Where-Object { $_.Name -like "$prefix*" }
foreach ($vm in $vms) {
    $vmName = $vm.Name
    Write-Output "Setting auto-shutdown for VM: $vmName"
    az vm auto-shutdown --resource-group $resourceGroupName --name $vmName --time 18:00 
}

# ---------------------#
#     ROLE ASSIGNMENTS #
# ---------------------#
Write-Host "`nAssigning RBAC roles..."
New-AzRoleAssignment -ObjectId $userGroupId -RoleDefinitionName "Virtual Machine User Login" -Scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName"
New-AzRoleAssignment -ObjectId $adminGroupId -RoleDefinitionName "Virtual Machine User Login" -Scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName"
New-AzRoleAssignment -ObjectId $adminGroupId -RoleDefinitionName "Virtual Machine Administrator Login" -Scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName"

$avdServicePrincipal = Get-AzADServicePrincipal -DisplayName "Azure Virtual Desktop"
$avdServicePrincipalId = $avdServicePrincipal.Id
New-AzRoleAssignment -ObjectId $avdServicePrincipalId -RoleDefinitionName "Desktop Virtualization Power On Contributor" -Scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName"

# ---------------------#
#   APP GROUP CHECK    #
# ---------------------#

$appGroup = Get-AzWvdApplicationGroup -Name $appGroupName -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
if (-not $appGroup) {
    Write-Host "Application Group '$appGroupName' does not exist in resource group '$resourceGroupName'."
    Write-Host "Please create it in the Azure Portal or with PowerShell before running the rest of this script."
    exit 1
}
$appGroupPath = $appGroup.Id

New-AzRoleAssignment -ObjectId $userGroupId -RoleDefinitionName "Desktop Virtualization User" -Scope $appGroupPath
New-AzRoleAssignment -ObjectId $adminGroupId -RoleDefinitionName "Desktop Virtualization User" -Scope $appGroupPath

$sessionDesktop = Get-AzWvdDesktop -ResourceGroupName $resourceGroupName -ApplicationGroupName $appGroupName -Name "SessionDesktop" -ErrorAction SilentlyContinue
if ($sessionDesktop) {
    Update-AzWvdDesktop -ResourceGroupName $resourceGroupName -ApplicationGroupName $appGroupName -Name "SessionDesktop" -FriendlyName "Kemponline Desktop"
}

# ---------------------#
#  STORAGE APP CONSENT #
# ---------------------#
Write-Host "`n=== Storage App: Grant Graph Consent & Exclude from Conditional Access Policies ==="
$storageApp = Get-MgServicePrincipal -Filter "displayName eq '$storageAppDisplayName'"
if (-not $storageApp) {
    Write-Host "Service Principal '$storageAppDisplayName' not found. Searching for similar names..." -ForegroundColor Yellow
    $similarApps = Get-MgServicePrincipal -Filter "startswith(displayName,'$storageAppDisplayName')" -All
    if ($similarApps) {
        Write-Host "Did you mean one of these?"
        $similarApps | Select-Object DisplayName,Id
    }
    Write-Host "You can verify the display name in Entra ID > Enterprise Applications."
    exit 1
}

Write-Host "`nGranting admin consent for Graph permissions (if required)..."
try {
    # List all required resource access for the app to find Graph scopes
    $reqAccess = $storageApp.AppRolesAssigned
    Write-Host "If any permissions require admin consent, please review and grant in the Entra portal."
} catch {
    Write-Host "Could not enumerate required permissions. Please verify manually in Entra."
}

Write-Host "`nChecking Conditional Access policies..."
$policies = Get-MgConditionalAccessPolicy
foreach ($policy in $policies) {
    $excludedApps = $policy.Conditions.Applications.ExcludeApplications
    if ($excludedApps -notcontains $storageApp.Id) {
        $newExcludedApps = $excludedApps + $storageApp.Id
        try {
            Update-MgConditionalAccessPolicy -ConditionalAccessPolicyId $policy.Id -Conditions @{
                Applications = @{
                    IncludeApplications = $policy.Conditions.Applications.IncludeApplications
                    ExcludeApplications = $newExcludedApps
                }
            }
            Write-Host "Updated policy $($policy.DisplayName) to exclude $storageAppDisplayName"
        } catch {
            Write-Host "Failed to update policy $($policy.DisplayName): $_"
        }
    } else {
        Write-Host "Policy $($policy.DisplayName) already excludes $storageAppDisplayName"
    }
}

Write-Host "`n--- Script Complete ---"
Write-Host "Please verify:"
Write-Host "- Storage App permissions and consent in Entra Portal"
Write-Host "- Conditional Access exclusions"
Write-Host "- Internal DNS record creation for the storage account private endpoint (manual on your DNS server)"