# ===============================
# Azure Virtual Desktop Automation
# ===============================

Write-Host "Select which part of the script to run:"
Write-Host "1. Run full script (AVD setup + Storage App CA exclusion)"
Write-Host "2. Run Storage App CA exclusion only"
$mainChoice = Read-Host "Enter 1 or 2"

if ($mainChoice -eq "2") {
    # ===========================
    # PART 2: Storage App CA exclusion
    # ===========================

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
        Install-Module Microsoft.Graph -Scope CurrentUser -Force
    }
    Import-Module Microsoft.Graph -ErrorAction SilentlyContinue

    Write-Host "Connecting to Microsoft Graph..."
    Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess","Directory.Read.All","Application.ReadWrite.All"

    Write-Host ""
    Write-Host "How do you want to choose the storage account application?"
    Write-Host "1. Enter the storage account name (e.g. mystorageaccount)"
    Write-Host "2. Select the storage account from a list"
    $choice = Read-Host "Enter 1 or 2"

    if ($choice -eq "1") {
        $enteredName = Read-Host "Enter the storage account name (e.g. mystorageaccount)"
        $filterQuery = "startswith(displayName,'[Storage Account] $enteredName')"
        $applications = Get-MgApplication -Filter $filterQuery -All
        if (-not $applications) {
            Write-Host "No Applications found with a display name starting with '[Storage Account] $enteredName'." -ForegroundColor Red
            exit 1
        }
        if ($applications.Count -gt 1) {
            Write-Host "`nMultiple matches found:"
            $counter = 1
            foreach ($app in $applications) {
                $name  = $app.DisplayName
                $id    = $app.Id
                $appid = $app.AppId
                if (-not $name)  { $name = "<No DisplayName>" }
                if (-not $id)    { $id = "<No ObjectId>" }
                if (-not $appid) { $appid = "<No AppId>" }
                Write-Host ("{0}. {1} | ObjectId: {2} | AppId: {3}" -f $counter, $name, $id, $appid)
                $counter++
            }
            $selection = Read-Host "Enter the number of the Application to select"
            if ($selection -notmatch '^\d+$' -or $selection -lt 1 -or $selection -gt $applications.Count) {
                Write-Host "Invalid selection!" -ForegroundColor Red
                exit 1
            }
            $selectedApp = $applications[$selection - 1]
        } else {
            $selectedApp = $applications | Select-Object -First 1
            Write-Host "Auto-selected Application: $($selectedApp.DisplayName)"
        }
    } elseif ($choice -eq "2") {
        $applications = Get-MgApplication -Filter "startswith(displayName,'[Storage Account]')" -All
        if (-not $applications) {
            Write-Host "No Applications found with a display name starting with '[Storage Account]'." -ForegroundColor Red
            exit 1
        }
        Write-Host "`nAvailable Storage Applications:"
        $counter = 1
        foreach ($app in $applications) {
            $name  = $app.DisplayName
            $id    = $app.Id
            $appid = $app.AppId
            if (-not $name)  { $name = "<No DisplayName>" }
            if (-not $id)    { $id = "<No ObjectId>" }
            if (-not $appid) { $appid = "<No AppId>" }
            Write-Host ("{0}. {1} | ObjectId: {2} | AppId: {3}" -f $counter, $name, $id, $appid)
            $counter++
        }
        $selection = Read-Host "Enter the number of the Application to select"
        if ($selection -notmatch '^\d+$' -or $selection -lt 1 -or $selection -gt $applications.Count) {
            Write-Host "Invalid selection!" -ForegroundColor Red
            exit 1
        }
        $selectedApp = $applications[$selection - 1]
        Write-Host "`nSelected Application:"
        Write-Host ("DisplayName: {0}" -f $selectedApp.DisplayName)
        Write-Host ("ObjectId:    {0}" -f $selectedApp.Id)
        Write-Host ("AppId:       {0}" -f $selectedApp.AppId)
    } else {
        Write-Host "Invalid choice!" -ForegroundColor Red
        exit 1
    }

    # Store as $CAExclude
    $CAExclude = $selectedApp.AppId
    Write-Host "`nSelected Application AppId to exclude: $CAExclude"

    # Get the Service Principal for info (optional)
    $spns = Get-MgServicePrincipal -Filter "appId eq '$CAExclude'" -All
    if (-not $spns) {
        Write-Host "No Service Principal found for AppId $CAExclude!" -ForegroundColor Red
    } else {
        $selectedSPN = $spns | Select-Object -First 1
        Write-Host "Corresponding Service Principal ObjectId: $($selectedSPN.Id)"
    }

    Write-Host "`nFinding Conditional Access policies that target All cloud apps (excluding Microsoft-managed policies)..."
    $allPolicies = Get-MgIdentityConditionalAccessPolicy -All
    $allAppsPolicies = $allPolicies | Where-Object {
        ($_.Conditions.Applications.IncludeApplications -contains "All") -and
        ($_.DisplayName -notlike '*Microsoft-managed*')
    }

    if (-not $allAppsPolicies) {
        Write-Host "No Conditional Access policies found that target all cloud apps." -ForegroundColor Yellow
        exit 1
    }
    Write-Host "Policies targeting all cloud apps:"
    $allAppsPolicies | ForEach-Object { Write-Host "- $($_.DisplayName) (ID: $($_.Id))" }

    foreach ($policy in $allAppsPolicies) {
        $appConds = $policy.Conditions.Applications
        $excludedApps = $appConds.ExcludeApplications

        if ($excludedApps -notcontains $CAExclude) {
            $newExcludedApps = $excludedApps + $CAExclude

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
                Write-Host "Updated policy $($policy.DisplayName) to exclude AppId $CAExclude"
            } catch {
                Write-Host "Failed to update policy $($policy.DisplayName): $_"
            }
        } else {
            Write-Host "Policy $($policy.DisplayName) already excludes AppId $CAExclude"
        }
    }

    Write-Host ""
    Write-Host "----- Complete -----"
    Write-Host "Please verify the CA exclusions in the Entra Portal."
    exit 0
}

# ===============================
# PART 1: FULL SCRIPT (AVD SETUP)
# ===============================

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

Write-Host ""
Write-Host "----- AVD Setup Complete -----"
Write-Host "If you need to manage Conditional Access exclusions for your storage app, please re-run this script and select option 2."