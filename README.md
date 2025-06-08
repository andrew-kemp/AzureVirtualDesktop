# Azure Virtual Desktop (AVD) – Automated Enterprise Deployment

This repository provides an end-to-end, modular automation suite for deploying Azure Virtual Desktop (AVD) in a secure, enterprise-ready configuration. All templates and scripts are designed for repeatability, security, and clarity, with a workflow that leverages Bicep, ARM JSON, and PowerShell for every step of the deployment.

---

## 📁 Repository Contents

| Step | File Name                                | Purpose                                                                             | Run Location                  |
|------|------------------------------------------|-------------------------------------------------------------------------------------|-------------------------------|
| 1    | `01-Deploy-CoreAVDInfra.bicep/json`      | Deploy core AVD infra: storage, networking, host pool, app group, workspace, RBAC    | Azure CLI/Portal              |
| 2    | `02-Deploy-SessionHosts.Bicep/json`      | Deploy and register session host VMs with all required extensions                    | Azure CLI/Portal              |
| 2a   | `02a-SessionHostPrep.ps1`                | Prepare session host OS for FSLogix, Kerberos, and cleanup (runs as VM extension)    | VM Extension (auto)           |
| 3    | `03-AVD-Ent-Config.ps1`                  | Configure AAD groups, RBAC, VM auto-shutdown, Conditional Access exclusions          | Azure Cloud Shell/PowerShell  |
| 4    | `04-Add-StorageDNSRecord.ps1.ps1`        | Add internal DNS A record for storage private endpoint                               | DNS/Admin Server              |
| 5    | `05-MountAndSetSharePermissions.ps1`     | Mount Azure Files shares, set NTFS permissions for FSLogix                           | Hybrid-joined Device          |

---

## 🚀 Quick Start

1. **Clone the repository**
   ```sh
   git clone https://github.com/andrew-kemp/AzureVirtualDesktop.git
   cd AzureVirtualDesktop
   ```

2. **Follow the deployment steps in order:**

   - **Step 1:** Deploy core infrastructure  
     `01-Deploy-CoreAVDInfra.bicep` or `01-Deploy-CoreAVDInfra.json`  
     _Deploy using Azure CLI, PowerShell, or the portal. You will need to provide details such as storage account name, Kerberos AD settings, vNet/subnet info, and AAD group object IDs._

   - **Step 2:** Deploy session hosts  
     `02-Deploy-SessionHosts.Bicep` or `02-Deploy-SessionHosts.json`  
     _Requires registration key output from the Host Pool in Step 1. Specify session host count, admin credentials, vNet/subnet, storage info, and optionally DNS servers._

   - **Step 2a:** Session host preparation  
     `02a-SessionHostPrep.ps1`  
     _Runs automatically as a VM custom script extension—do not run manually. Configures FSLogix, Cloud Kerberos, and removes unwanted apps._

   - **Step 3:** Configure AVD roles, groups, and policies  
     `03-AVD-Ent-Config.ps1`  
     _Run interactively in Azure Cloud Shell or PowerShell with required modules. Sets up or reuses AAD groups, applies RBAC, enables VM auto-shutdown, and assists with Conditional Access exclusions._

     **⚠️ IMPORTANT: After running this script, you MUST manually grant admin consent for the Storage Account App in the Entra Portal.**
     - The app will be listed as `[Storage Account] mystorage.file.core.windows.net` (replace with your storage account name).
     - Go to **Azure Portal > Entra ID > App registrations > [Storage Account]... > API permissions > Grant admin consent**.
     - **This step is mandatory – if you skip it, FSLogix shares and user profiles will not work!**

   - **Step 4:** Add DNS record for storage  
     `04-Add-StorageDNSRecord.ps1.ps1`  
     _Run on your DNS management server. Prompts for DNS server, zone, storage account, and private endpoint IP. Creates missing zones/records as needed._

   - **Step 5:** Mount shares and set permissions  
     `05-MountAndSetSharePermissions.ps1`  
     _Run on a hybrid-joined Windows device. Maps FSLogix profile and redirection shares, applies secure NTFS permissions for user/admin groups, then disconnects._

---

## 📝 Script & Template Details

- **01-Deploy-CoreAVDInfra (Bicep/JSON):**
  - Deploys storage (with Azure AD Kerberos/private endpoint), networking, FSLogix shares, host pool, app group, and workspace.
  - Sets up least-privilege RBAC for storage access using group Object IDs.
  - Outputs resource IDs for use in following steps.

- **02-Deploy-SessionHosts (Bicep/JSON):**
  - Provisions Windows 11 AVD session hosts, joins vNet, configures DNS, registers hosts to the pool.
  - Attaches extensions for Entra ID join, guest attestation, and session host prep.
  - Outputs post-deployment manual steps for AVD app registration, CA policy, folder permissions, and DNS.

- **02a-SessionHostPrep.ps1:**
  - Configures FSLogix registry, enables Cloud Kerberos, and removes preinstalled UWP/Store apps.
  - Runs automatically on each session host as a VM extension.

- **03-AVD-Ent-Config.ps1:**
  - Interactive PowerShell script for configuring AAD groups (user, admin, device), assigning permissions, and updating Conditional Access policies.
  - Ensures correct group memberships, role assignments, and auto-shutdown schedules.
  - Assists with CA exclusion for the Storage App and prompts for required admin consent.
  - **Manual Step Required:**  
    - After the script, go to the Entra Portal and grant admin consent to the Storage Account App (named `[Storage Account] mystorage.file.core.windows.net`).  
    - **Without this, FSLogix profile shares will NOT work.**

- **04-Add-StorageDNSRecord.ps1.ps1:**
  - Adds a DNS A record for your storage account’s private endpoint in the correct DNS zone.
  - Ensures the zone and record exist, creating as necessary.
  - Intended for Windows DNS servers with the DNSServer module.

- **05-MountAndSetSharePermissions.ps1:**
  - Maps `profiles` and `redirections` shares by UNC path, sets NTFS permissions for AVD user/admin groups.
  - Designed for hybrid-joined Windows clients.
  - Verifies share mapping and permission application, cleans up after execution.

---

## ⚠️ Prerequisites

- Azure subscription with resource deployment permissions
- Azure CLI, PowerShell, and/or Portal access
- Admin permissions on AD/DNS servers (for steps 4 & 5)
- [FSLogix licensing](https://docs.microsoft.com/en-us/fslogix/)
- Hybrid identity setup (Azure AD + Active Directory)
- PowerShell modules: `Az`, `Microsoft.Graph`, `DNSServer` as required

---

## 🔐 Security & Best Practices

- All storage and AVD resources use private endpoints and strict network ACLs
- Permissions are group-based for least-privilege access
- Manual steps (DNS, consent, CA) are clearly indicated in output/scripts
- Scripts and templates are idempotent and safely re-runnable

---

## 🤝 Contributions & Support

Maintained by [andrew-kemp](https://github.com/andrew-kemp).

Contributions and feedback are welcome!  
Please open [issues](https://github.com/andrew-kemp/AzureVirtualDesktop/issues) or submit pull requests for improvements and fixes.

---

## 📄 License

MIT License – see [LICENSE](LICENSE) for details.