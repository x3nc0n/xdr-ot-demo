# Deployment and configuration runbook

Run only in an authorized synthetic lab. Steps are ordered; **do not skip the
private-management and response-policy gates to make onboarding easier**.
Commands containing `<...>` require your values. Nothing in this runbook should
be run against production systems.

## 1. Operator preflight (manual)

- Choose the Azure subscription, Entra tenant, resource group and location.
  East US 2 is the default, not a guarantee of capacity or data residency.
- Confirm VM quota and the Windows/Ubuntu marketplace images in the selected
  region, Windows 11 virtualization rights, MDE client/server licenses and
  Sentinel costs. The WEC is a server too if you later enable MDE on it.
- Review Azure Policy and Defender for Cloud auto-provisioning. They must not
  reinstall Compute VM extensions after Arc conversion, or onboard the same
  OS under both Compute and Arc automatically.
- Register required providers if missing: Compute, Network, OperationalInsights,
  Insights, SecurityInsights, HybridCompute and GuestConfiguration. Provider
  registration/subscription policy changes require the subscription owner.
- Review [response guardrails](response-guardrails.md). No tenant-wide changes
  are implicitly authorized by deploying this template.
- Review `config\endpoints.json`. Allow agent dependencies and certificate checks
  without TLS interception. Stage installer/package redirects narrowly if the
  current signed packages use additional hosts.

## 2. Deploy the foundation

Use the README button after publishing the generated files, or use local ARM.
The deployment asks for administrator credentials and Linux SSH public key.
Keep local parameter files outside source control (`private*.json` is ignored).
Prefer a Key Vault parameter reference over a plaintext password file.
For that option, the vault must permit ARM template deployment and the deploying
identity must have the vault deployment permission. Have the vault owner review
that access; the lab template does not enable it or grant itself secret access.

`scripts\Deploy-Lab.ps1` defaults to **what-if** against an existing resource
group. `-Apply -LicensingAndCostReviewed` plus confirmation creates/updates paid
resources. The helper uses explicit subscription arguments and does not change
your default Azure subscription.

Retrieve outputs:

```powershell
New-Item -ItemType Directory .\.local -Force | Out-Null
az deployment group show --subscription '<subscription-guid>' `
  --resource-group 'rg-ot-demo' --name 'ot-lab' `
  --query properties.outputs --output json |
  Set-Content .\.local\outputs.json
```

For portal deployments substitute the actual deployment name. Outputs contain
addresses/resource IDs, not credentials. The button deploys the foundation only:
Arc registration, MDE onboarding, WEF certificates and tenant controls are later
steps.

`vmNames` and `privateIps` use the keys `management`, `l2`, `l3Windows`,
`l3Linux`, `wec` and `proxy`. `dcrIds` uses `localSecurity`, `wef` and `syslog`.
`proxyUrl` and `collectorFqdn` are ready to use in guest configuration.

## 3. Establish private administration and verify proxy bootstrap

1. Connect in the portal through **Bastion to the management VM**. Use that VM
   for private RDP/SSH and file staging. No public SSH/RDP rule is needed.
2. Verify private RDP to Windows targets/WEC and SSH to Linux/proxy. Record
   recovery credentials securely. Install PowerShell 7/OpenSSL on the management
   host from approved staged packages if using the PKI helper.
3. On the proxy inspect `cloud-init status --wait`, `/var/log/cloud-init-output.log`,
   `systemctl status squid` and `sudo squid -k parse`. If package bootstrap fails,
   inspect Firewall application denies; do not temporarily allow all Internet.
4. Verify approved cloud access through `http://<proxy-private-ip>:3128`, denied
   access to `https://example.com`, and denied direct public egress from a plant
   host. Read both Firewall and Squid logs; a timeout alone is not proof.
5. Apply the static proxy separately to Arc, AMA, MDE/AV and package/update
   clients. The scripts do not configure interactive browsers to browse the
   Internet freely.

Bootstrap files travel via the private management path. Do not pass an MDE
onboarding bundle, private key or service-principal password in VM custom data,
ARM outputs, shell command-line arguments, transcripts or a public download URL.
Do not assume the deployed VMs can fetch this GitHub repository.

## 4. Stage packages and approve conversion

Stage signed Connected Machine agent installers for Windows and the supported
Ubuntu package. Record SHA-256 from an approved source and verify the Windows
publisher signature. Stage Linux prerequisites **before** guest-agent shutdown:
`nftables`, `curl`, `rsyslog` and any dependencies required by the current Arc
package. Use the explicit proxy for package retrieval.

On Windows, confirm elevated access. On Linux, confirm root/sudo and persistent
SSH. Read each script's actual interface:

```powershell
Get-Command .\scripts\ConvertTo-ArcLab.ps1 -Syntax
Get-Command .\scripts\Initialize-Lab.ps1 -Syntax
# Linux:
# bash scripts/ConvertTo-ArcLab.sh --help
```

On the Windows sensitive target (substitute `wec` for the collector):

```powershell
.\scripts\ConvertTo-ArcLab.ps1 -Role windows2022 `
  -ProxyUrl 'http://<proxy-private-ip>:3128' `
  -InstallerPath 'C:\staged\AzureConnectedMachineAgent.msi' `
  -InstallerSha256 '<approved-sha256>' `
  -TrustedSignerThumbprint '<verified-publisher-thumbprint>' `
  -ExtensionsRemovedVerified -PolicyRedeploymentPrevented -PrivateManagementVerified `
  -WhatIf
# Run again without -WhatIf only after completing the control-plane steps below.
```

In the Azure control plane, list and remove **all Compute VM extensions** from
the two sensitive servers and WEC. This is intentionally a separate, reviewed
step: extensions may contain unrelated protection/management policies.

```powershell
az vm extension list --subscription '<subscription-guid>' `
  --resource-group 'rg-ot-demo' --vm-name '<actual-server-vm-name>' --output table
# For each reviewed extension:
az vm extension delete --subscription '<subscription-guid>' `
  --resource-group 'rg-ot-demo' --vm-name '<actual-server-vm-name>' `
  --name '<reviewed-extension-name>'
# Repeat list and confirm an empty list; wait for removal to finish.
```

Repeat for the other sensitive server and WEC, **never Win11**. Ensure policy
will not put extensions back. A local script cannot independently prove this
control-plane prerequisite; its acknowledgment switch is an operator assertion.

## 5. Convert server-class guests to Arc

Run the relevant `ConvertTo-ArcLab` script **inside each server OS**, supplying
its locally staged package/hash and required management/extension-removal
acknowledgments. Use `Get-Command -Syntax` or `--help` for the required values.
Windows conversion rejects client operating systems.

On the Ubuntu sensitive target, after completing those same control-plane steps:

```bash
sudo bash scripts/ConvertTo-ArcLab.sh \
  --role linuxUbuntu24 --proxy-url http://PROXY-IP:3128 \
  --installer /opt/ot-demo/staged/azcmagent.deb --sha256 APPROVED-SHA256 \
  --extensions-removed-verified --policy-redeployment-prevented \
  --private-management-verified
```

The script sets the evaluation flag, disables/stops the Azure guest agent,
blocks both documented IMDS addresses persistently, installs Arc and configures
its explicit proxy. It must not be used to configure an existing production
server. Reboot and confirm private administration still works.

Complete Arc authentication with your approved scoped identity. Prefer the
documented interactive/device-code flow rather than putting a client secret
in a command:

```powershell
# Elevated inside the converted Windows server; use the Linux path on Ubuntu.
& "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe" connect `
  --subscription-id '<subscription-guid>' --tenant-id '<tenant-guid>' `
  --resource-group 'rg-ot-demo' --location 'eastus2' `
  --resource-name '<unique-arc-machine-name>' --use-device-code
& "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe" show
```

```bash
sudo env MSFT_ARC_TEST=true /opt/azcmagent/bin/azcmagent connect \
  --subscription-id '<subscription-guid>' --tenant-id '<tenant-guid>' \
  --resource-group 'rg-ot-demo' --location eastus2 \
  --resource-name '<unique-arc-machine-name>' --use-device-code
sudo /opt/azcmagent/bin/azcmagent show
```

Confirm these flags with the installed version's `connect --help`; apply the
operator's actual tenant policy. Use the same resource group/location as the
monitoring template. Keep the chosen Arc names for step 8.

Do not run `connect` again on an already-connected agent. Do not clone an
onboarded identity into another VM. Arc extensions and Arc's identity are
different from the removed Compute extensions and IMDS identity.

## 6. MDE and active AV

**First complete the canary/group-enrollment evidence in
[response-guardrails.md](response-guardrails.md).** Stop if scoped exclusion is
unavailable. The initial MDE scope is Win11 and the two sensitive targets;
collector/proxy/management MDE is optional and separately licensed/reviewed.

1. Run the OS-specific `Set-LabProtection` configuration with the correct proxy
   and explicit guardrails acknowledgment. Check its syntax/help first.
2. Download a **streamlined-connectivity** onboarding package from the existing
   tenant for each supported OS. Store it privately; verify its provenance and
   signature/hash. Do not commit it.
3. For Windows Server 2022 and Windows 11, run the tenant-provided local
   onboarding script elevated using Microsoft's current onboarding guidance.
   The required sensor/AV component versions must support streamlined endpoints.
4. On Ubuntu install MDE from the approved Microsoft repository/staged package
   and run the tenant-provided Linux onboarding process. Do not substitute
   Windows onboarding data or invent an onboarding blob.
5. Reapply/verify `Set-LabProtection` after installation where appropriate.
   Confirm active real-time AV, static proxy, narrow exclusions and expected
   device tags/group membership. Managed Intune/GPO policies may override local
   commands; resolve with the tenant owner, not by weakening tamper protection.
6. Verify Windows EDR and AV cloud connectivity independently. Verify Linux
   `mdatp health`, `mdatp connectivity test`, proxy and exclusion output.
7. Keep security-intelligence/platform updates working. Windows AV static proxy
   alone is not a Windows Update configuration. No automatic-reboot or
   disruptive response schedule is created by these scripts.

Windows configuration example, with the documented operator assertion:

```powershell
.\scripts\Set-LabProtection.ps1 -ProxyUrl 'http://<proxy-private-ip>:3128' `
  -DeviceTag 'OT-Demo-NoResponse' -ResponseGuardrailsVerified `
  -CertificateDistributionFqdn '<collector-fqdn>'
```

The optional certificate-distribution bypass permits local CRL retrieval rather
than sending that internal request to the public-destination proxy policy.

Linux configuration, after installing the supported MDE package:

```bash
sudo bash scripts/Set-LabProtection.sh \
  --proxy-url http://PROXY-IP:3128 --device-tag OT-Demo-NoResponse \
  --response-guardrails-verified
```

Synthetic heartbeat workloads emit harmless data/events only. See the workload
files and `config\workloads.json`. Run them after protection configuration; never
use exclusion examples for real vendor software without separate validation.
The mutable data-file exclusions do not exempt all application code or all
process activity.

Start the provided workloads only after protection is configured:

```powershell
.\workloads\windows\Install-Heartbeat.ps1
Start-ScheduledTask -TaskName OT-Lab-Heartbeat
```

```bash
sudo bash workloads/linux/install-heartbeat.sh
sudo systemctl start ot-lab-heartbeat.service
journalctl -t OT-Lab -n 5 --no-pager
```

## 7. HTTPS WEF without Active Directory

### Issue certificates (private management host)

Use your approved lab CA, or the included Windows/PowerShell 7 helper:

```powershell
.\scripts\New-LabPki.ps1 -CollectorFqdn '<collector-fqdn>' `
  -SourceFqdn '<win11-fqdn>' -OutputDirectory 'C:\OTLab-PKI' `
  -OpenSslPath 'C:\Program Files\Git\usr\bin\openssl.exe'
```

It issues 90-day server/client leaf certificates from an encrypted lab root and
a CRL valid for 30 days. It does not create self-signed leaf certificates.
The output directory must be new; it is ACL-restricted to the operator and
SYSTEM. The root private key **stays on this host**. Protect and back up CA state.

Distribute only:

| Destination | Files |
|---|---|
| Win11 | `root.cer`, `source.pfx` |
| WEC | `root.cer`, `collector.pfx`, public `lab.crl` |
| Other machines if required for trust testing | public `root.cer` only |

Use private RDP file transfer; never public blob URLs for private keys.
Import the root into LocalMachine Root and each appropriate PFX into
LocalMachine My with secure password input; do not mark the leaf key exportable:

```powershell
Import-Certificate -FilePath 'C:\staged\root.cer' -CertStoreLocation Cert:\LocalMachine\Root
$pfxPassword = Read-Host 'PFX password' -AsSecureString
Import-PfxCertificate -FilePath 'C:\staged\collector.pfx' `
  -CertStoreLocation Cert:\LocalMachine\My -Password $pfxPassword
# On Win11 substitute source.pfx. Remove transferred PFX after verified import.
```

Use FQDNs that resolve privately from both machines. Configure private DNS or
explicit lab hosts-file entries with the template's actual private IPs.
Certificate CN/SAN, listener name and subscription name must agree.

### Publish revocation data first (WEC)

On WEC install the IIS static-content role and publish **only** the public CRL:

```powershell
Install-WindowsFeature Web-Server,Web-Static-Content
New-Item -ItemType Directory 'C:\inetpub\wwwroot\pki' -Force
Copy-Item 'C:\staged\lab.crl' 'C:\inetpub\wwwroot\pki\lab.crl'
# If .crl is not already defined in IIS MIME Types:
& "$env:SystemRoot\System32\inetsrv\appcmd.exe" set config /section:staticContent `
  "/+[fileExtension='.crl',mimeType='application/pkix-crl']" /commit:apphost
# Disable the broad IIS-created HTTP host rule, then allow only approved clients:
Get-NetFirewallRule -Name 'IIS-WebServerRole-HTTP-In-TCP' -ErrorAction SilentlyContinue |
  Disable-NetFirewallRule
New-NetFirewallRule -Name 'OTLab-CRL-HTTP' -DisplayName 'OT Lab CRL HTTP' `
  -Direction Inbound -Action Allow -Protocol TCP -LocalPort 80 `
  -RemoteAddress '<win11-private-ip>'
```

Remove unused default web content and keep directory browsing off. Network
templates permit the approved internal CRL path, not Internet hosting. Confirm
`http://<collector-fqdn>/pki/lab.crl` is reachable and `certutil -verify -urlfetch`
validates the leaf chain. Do **not** disable revocation checking.

Renew the CRL before expiry using protected operator CA state:

```powershell
# Inside the protected CA directory; prompts securely for encrypted root key:
openssl ca -gencrl -config openssl.cnf -out lab.crl.pem
openssl crl -in lab.crl.pem -outform DER -out lab.crl
```

Republish the public CRL. For revocation use `openssl ca -revoke <issued-leaf.cer>
-config openssl.cnf`, generate/republish a new CRL and issue replacement leaves.
Retain the CA database/serial state. Leaf renewal is an explicit new issuance;
do not rerun the new-CA helper over existing state.

### Configure collector/source

Run `Initialize-Wef.ps1` on WEC in collector mode, then on Win11 in source mode,
using the issued leaf/root thumbprints, exact source/collector identities and
its required mapping credential. Inspect the script's parameter syntax; a
local account used by the documented non-domain WinRM certificate mapping is
not a domain join or general Basic authentication.

```powershell
Get-Command .\scripts\Initialize-Wef.ps1 -Syntax
# Collector: use a pre-created, lab-only local mapping account with the
# privileges required by Microsoft's non-domain WEF procedure.
$mappingCredential = Get-Credential -UserName '<collector-name>\labwef'
.\scripts\Initialize-Wef.ps1 -Mode Collector `
  -CertificateThumbprint '<collector-leaf-thumbprint>' `
  -IssuerCaThumbprint '<root-ca-thumbprint>' -CollectorFqdn '<collector-fqdn>' `
  -AllowedSourceFqdn '<win11-fqdn>' -SourceAddress '<win11-private-ip>' `
  -MappingCredential $mappingCredential
# Workstation:
.\scripts\Initialize-Wef.ps1 -Mode Source `
  -CertificateThumbprint '<source-leaf-thumbprint>' `
  -IssuerCaThumbprint '<root-ca-thumbprint>' `
  -CollectorFqdn '<collector-fqdn>' -SourceFqdn '<win11-fqdn>'

winrm enumerate winrm/config/listener
wecutil enum-subscription
wecutil get-subscriptionruntimestatus OT-Lab
```

The source needs Network Service access to its certificate private key and
event channels. The helper applies only the intended configuration; do not
add wildcard TrustedHosts, unencrypted WinRM or a blanket inbound WinRM rule.
Configure selected audit events deliberately; WEF cannot turn audit policy on
merely by subscribing.

Generate a harmless synthetic event with a unique correlation ID. Verify it
arrives in WEC's `ForwardedEvents`. Reject a source with an untrusted
certificate before proceeding.

On the workstation, inspect the required audit policy separately. For example,
after approving the lab's event selection, enable successful/failed logon
auditing with `auditpol /set /subcategory:"Logon" /success:enable /failure:enable`.
Localized Windows installations use localized subcategory names; use
`auditpol /list /subcategory:*` to select the right one. Do not blanket-enable
all audit categories or flood the workspace.

## 8. Attach AMA to the Arc machines

Once all three Arc resources report Connected, deploy the separate
`infra\arc-monitoring.bicep` (or its generated ARM JSON). Supply the actual
Arc names, main deployment DCR resource IDs and proxy URL. Use:

```powershell
az bicep build --file .\infra\arc-monitoring.bicep
az deployment group create --subscription '<subscription-guid>' `
  --resource-group 'rg-ot-demo' --template-file .\infra\arc-monitoring.json `
  --parameters '@<private-arc-parameters.json>'
```

Parameter names are listed in that Bicep/template. No managed-identity client ID
is supplied: AMA on Arc uses the Arc machine's system-assigned identity.
The extension proxy is explicit; it does not rely on Arc inheritance.

The required Arc parameter names are `windowsMachineName`, `wecMachineName`,
`linuxMachineName`, `proxyUrl`, `localSecurityDcrId`, `wefDcrId` and
`syslogDcrId`; `location` must match the Arc resources. Use the resource IDs from
the main deployment's `dcrIds` output and the actual names chosen during
`azcmagent connect`, not assumptions based on Compute VM resource names.

For example, construct the Arc parameter file from the saved outputs after
filling the actual three Arc names:

```powershell
$o = Get-Content .\.local\outputs.json -Raw | ConvertFrom-Json
$arc = @{
  '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
  contentVersion = '1.0.0.0'
  parameters = @{
    windowsMachineName = @{ value = '<actual-windows-arc-name>' }
    wecMachineName = @{ value = '<actual-wec-arc-name>' }
    linuxMachineName = @{ value = '<actual-linux-arc-name>' }
    location = @{ value = 'eastus2' }
    proxyUrl = @{ value = $o.proxyUrl.value }
    localSecurityDcrId = @{ value = $o.dcrIds.value.localSecurity }
    wefDcrId = @{ value = $o.dcrIds.value.wef }
    syslogDcrId = @{ value = $o.dcrIds.value.syslog }
  }
}
$arc | ConvertTo-Json -Depth 8 | Set-Content .\.local\private.arc.parameters.json
# Use --parameters '@.local\private.arc.parameters.json' in the deployment command.
```

Confirm the current Windows Forwarded Events solution/connector availability
and data schema in the tenant. The templates define matching AMA streams:
forwarded events go to `WindowsEvent`, local server Security goes to
`SecurityEvent`, Linux selected syslog goes to `Syslog`. Install relevant
Sentinel content/parsers manually if needed; many built-in SecurityEvent rules
will not match forwarded WindowsEvent records without adaptation.

## 9. Cloud integration and acceptance

Have the tenant owner perform the approved service-side XDR/Sentinel connector
steps in [response guardrails](response-guardrails.md). Do not enable all hunting
tables or incident automation by default.

Run `scripts\Test-Lab.ps1` inside each Windows role and `scripts\Test-Lab.sh`
inside the Linux target. These are local diagnostics, not tenant-policy proof.
Use `queries\telemetry.kql` and `queries\network-denies.kql` in Sentinel.

Acceptance requires all of the following:

- Effective UDR/NSG evidence, permitted proxy/management/WEF paths, denied direct
  and non-allowlisted egress, denied unapproved east-west traffic.
- Proxy and Firewall records correlate with both halves of a permitted cloud
  session; no broad network rule bypasses FQDN policy.
- All three converted servers remain accessible privately after reboot, with
  disabled Azure guest agents, persistent IMDS blocks, stable Arc identity,
  healthy AMA and DCRs on the Arc resource. Win11 guest agent remains running.
- Three target MDE health records, active AV and expected narrow exclusions,
  verified no-automated-response scope and unchanged non-demo settings.
- A unique Win11 event in `WindowsEvent`, a Windows-server Security event in
  `SecurityEvent`, and Linux `local0` heartbeat in `Syslog`.
- Benign XDR incident/alert visibility only through the approved connector;
  no playbook/automatic response was introduced.
- Temporary proxy outage does not create direct fallback. Synthetic workloads
  continue; recovery and measured gaps/buffering are recorded separately for
  each agent. Do not claim unlimited disconnected buffering.
- Reconfiguration is idempotent and does not duplicate identities, remove
  unrelated firewall rules, broaden ACLs or rotate certificates unexpectedly.

Save sanitized evidence outside git. Until these live steps run, the build is
locally validated deployment material, not a proven deployed environment.

## 10. Recovery and cleanup

If a converted guest is inaccessible, use validated private credentials and
network paths first. Do not assume Compute VM Run Command/VMAccess can recover
a disabled guest agent. Use approved offline OS-disk repair or rebuild from
clean image, with proper Arc/MDE offboarding and new identities as needed.

For teardown:

1. Export needed lab evidence. Offboard MDE with the tenant's current package
   and disconnect Arc while connectivity is available.
2. Remove only lab-owned device groups/tags, connector settings and scoped
   policies with the tenant owner; preserve shared/production integrations.
3. Confirm no shared resources were placed in the lab resource group.
4. Use `Remove-Lab.ps1` with exact resource-group confirmation, tag `otDemo=true`
   and `-OffboardingAndTenantCleanupComplete`. It prompts before resource-group
   deletion and does not touch the repository or other resource groups.
5. Verify Firewall/Bastion/public IPs/disks and any residual Arc resources are
   gone, and inspect remaining charges. VM shutdown alone is not teardown.
