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

$prefix = Read-Host -Prompt "Enter the AVD Session Host prefix or press enter to use the Default of AVD"
if ([string]::IsNullOrWhiteSpace($prefix)) { $prefix = "AVD" }

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