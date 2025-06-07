<#
    AVD-Phase3.ps1 (Azure Cloud Shell Optimized)
    - Run in Azure Cloud Shell (https://shell.azure.com or Portal > Cloud Shell)
    - Az PowerShell modules are pre-installed.
    - Microsoft.Graph modules will be installed to your user profile if not present.
    - You are already authenticated, but the script will ensure correct context.
    - Both PowerShell and Azure CLI commands are supported in Cloud Shell.
    - If you need to persist files, use $HOME/clouddrive.
#>

# Function to check if a module is installed (for Microsoft.Graph modules)
function Install-ModuleIfNotInstalled {
    param ([string]$ModuleName)
    if (-not (Get-Module -ListAvailable -Name $ModuleName)) {
        Install-Module -Name $ModuleName -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    }
}

# Only install Microsoft.Graph modules if missing
Install-ModuleIfNotInstalled -ModuleName "Microsoft.Graph"
Install-ModuleIfNotInstalled -ModuleName "Microsoft.Graph.Identity.SignIns"
Install-ModuleIfNotInstalled -ModuleName "Microsoft.Graph.Applications"

# ---------------------#
#     USER PROMPTS     #
# ---------------------#

$resourceGroupName = Read-Host -Prompt "Enter the name of the resource group for your AVD hosts"
$prefix = Read-Host -Prompt "Enter the Session Host Prefix (press enter to use the default of AVD)"
if ([string]::IsNullOrWhiteSpace($prefix)) { $prefix = "AVD" }

$appGroupName = Read-Host -Prompt "Enter the Application Group name (default: ${prefix}-AppGroup)"
if ([string]::IsNullOrWhiteSpace($appGroupName)) { $appGroupName = "${prefix}-AppGroup" }

# Subscription selection (list at top for easier reference)
$subscriptions = Get-AzSubscription
if ($subscriptions.Count -eq 0) { Write-Host "No subscriptions found. Exiting."; exit 1 }
for ($i = 0; $i -lt $subscriptions.Count; $i++) {
    Write-Host "$i. $($subscriptions[$i].Name) - $($subscriptions[$i].Id)"
}
$subscriptionNumber = Read-Host -Prompt "Enter the number of the subscription from the list above"
if (-not [int]::TryParse($subscriptionNumber, [ref]$null) -or $subscriptionNumber -lt 0 -or $subscriptionNumber -ge $subscriptions.Count) {
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

Write-Host "`nSummary of your choices:"
Write-Host "Resource group: $resourceGroupName"
Write-Host "Session Host Prefix: $prefix"
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
$proceed = Read-Host "Proceed with these settings? (Y/N)"
if ($proceed -notin @('Y', 'y')) {
    Write-Host "Exiting."
    exit
}

# ---------------------#
#      AZURE LOGIN     #
# ---------------------#

Write-Host "`nConnecting to Azure and Microsoft Graph..."
# Cloud Shell is already signed in; these are safe to re-run
Connect-AzAccount -WarningAction SilentlyContinue | Out-Null
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

# Ensure az CLI is using the same subscription as Az PowerShell
az account set --subscription $subscriptionId

$vms = Get-AzVM -ResourceGroupName $resourceGroupName | Where-Object { $_.Name -like "$prefix*" }
foreach ($vm in $vms) {
    $vmName = $vm.Name
    Write-Host "Setting auto-shutdown for VM: $vmName"
    az vm auto-shutdown --resource-group $resourceGroupName --name $vmName --time 18:00 --subscription $subscriptionId
}

# ---------------------#
#     ROLE ASSIGNMENTS #
# ---------------------#
Write-Host "`nAssigning RBAC roles..."
function Ensure-RoleAssignment {
    param(
        [string]$ObjectId,
        [string]$RoleDefinitionName,
        [string]$Scope
    )
    $existing = Get-AzRoleAssignment -ObjectId $ObjectId -RoleDefinitionName $RoleDefinitionName -Scope $Scope -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-AzRoleAssignment -ObjectId $ObjectId -RoleDefinitionName $RoleDefinitionName -Scope $Scope
    } else {
        Write-Host "Role '$RoleDefinitionName' already assigned at $Scope"
    }
}

$resourceScope = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName"
Ensure-RoleAssignment -ObjectId $userGroupId -RoleDefinitionName "Virtual Machine User Login" -Scope $resourceScope
Ensure-RoleAssignment -ObjectId $adminGroupId -RoleDefinitionName "Virtual Machine User Login" -Scope $resourceScope
Ensure-RoleAssignment -ObjectId $adminGroupId -RoleDefinitionName "Virtual Machine Administrator Login" -Scope $resourceScope

$avdServicePrincipal = Get-AzADServicePrincipal -DisplayName "Azure Virtual Desktop"
$avdServicePrincipalId = $avdServicePrincipal.Id
Ensure-RoleAssignment -ObjectId $avdServicePrincipalId -RoleDefinitionName "Desktop Virtualization Power On Contributor" -Scope $resourceScope

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

Ensure-RoleAssignment -ObjectId $userGroupId -RoleDefinitionName "Desktop Virtualization User" -Scope $appGroupPath
Ensure-RoleAssignment -ObjectId $adminGroupId -RoleDefinitionName "Desktop Virtualization User" -Scope $appGroupPath

$sessionDesktop = Get-AzWvdDesktop -ResourceGroupName $resourceGroupName -ApplicationGroupName $appGroupName -Name "SessionDesktop" -ErrorAction SilentlyContinue
if ($sessionDesktop) {
    Update-AzWvdDesktop -ResourceGroupName $resourceGroupName -ApplicationGroupName $appGroupName -Name "SessionDesktop" -FriendlyName "Kemponline Desktop"
}

# --------------------------#
#  STORAGE APP CA Exclusion #
# --------------------------#
# The Storage App Display Name and Storage Account FQDN are now only prompted and processed in this section (no duplicate prompt earlier!)

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