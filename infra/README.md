# Infrastructure boundary

`main.bicep` targets a **dedicated lab resource group**. `azuredeploy.json` is its generated self-contained ARM equivalent: nested deployments contain inline templates, never linked templates. `createUiDefinition.json` supplies the portal inputs. Regenerate ARM after changing Bicep, proxy files or `config/egress.json`:

```powershell
az bicep build --file infra\main.bicep --outfile infra\azuredeploy.json
az bicep build --file infra\arc-monitoring.bicep --outfile infra\arc-monitoring.json
```

`parameters\lab.bicepparam` reads `OTLAB_ADMIN_PASSWORD` and `OTLAB_SSH_PUBLIC_KEY` from the process environment. Do not commit generated parameter files. Windows passwords are secure parameters; custom data contains only proxy configuration, public endpoint names and private addresses. No VM has a public IP. All six VMs start with guest agents for provisioning; the separate, explicitly gated conversion process disables agents on the three Arc evaluation servers. This template does **not** perform conversion, MDE onboarding, PKI issuance, or shared XDR integration.

Alternatively, copy `parameters\private.parameters.example.json` to your ignored local parameter file, replace the example Key Vault resource ID/secret name and SSH **public** key, and leave `adminPassword.reference` intact. The existing vault must permit ARM template deployment and the deploying principal must have the required `Microsoft.KeyVault/vaults/deploy/action` permission; this repository does not change those settings or create a secret. The example contains no password value and is not deployable until its public placeholders are replaced.

## Network controls

- Firewall **Basic** has independent data and management NICs, /26 subnets and Standard static public IPs. There are no DNAT rules.
- Bastion **Basic** has no subnet NSG or forced-tunnel route table. This deliberately preserves all Bastion platform traffic; its only workload access is private management-host RDP allowed by that host's NSG.
- Four independent plant subnets, management and proxy subnets disable default outbound access. Each has an explicit outbound deny before Azure's default rules.
- Plant-to-DMZ and all inter-subnet plant traffic use specific firewall UDRs, including WEF and return traffic. There is no plant-to-DMZ peering. Firewall network rules allow only plant-to-proxy TCP 3128, L2-to-WEC TCP 5986 and Windows-to-WEC CRL HTTP. Other inter-subnet plant flows fail.
- Hub management uses direct hub/spoke peerings to reach guest RDP/SSH, private proxy 3128 and WEC CRL HTTP. Firewall private network flows retain source addresses under Azure Firewall's default RFC1918 no-SNAT behavior.
- Only the proxy IP has public HTTP/HTTPS firewall application permits. There is **no public TCP 443 network permit** and no plant Internet permit. Workload NSGs allow AzurePlatformDNS 53 and wire-server TCP 80/32526 separately, not arbitrary public DNS. Time uses Azure's host-provided synchronization; public NTP is not opened.
- The proxy NSG permits Internet TCP 80/443 **only into its forced firewall route**. FQDN enforcement happens at the firewall and Squid, not the NSG.
- Address ranges are parameterized as one `addressPlan` object. Supply nonoverlapping RFC1918 ranges, /26 or larger dedicated Firewall/Bastion subnets, and workload subnets with host offset 4 free.

## Endpoint/bootstrap details

The generated manifest is embedded at compile time. `{region}` and `{workspaceId}` tokens are resolved at deployment; `workspaceId` here means the workspace **customer GUID**, not its Azure resource ID. The exact deployed workspace GUID `.ods.opinsights.azure.com` and regional AMA control endpoint are always added to both enforcement layers, without a broad ingestion-domain wildcard.

Proxy cloud-init embeds the complete configuration and ACL files: no external script URL or deployment secret. Ubuntu 24.04 apt sources are pinned to HTTP `archive.ubuntu.com` and `security.ubuntu.com`, with normal Ubuntu repository signature verification. Those two exact hosts have proxy-source-only firewall permits before Squid exists. No `apt upgrade` runs; automatic apt timers are disabled. Squid is masked during package installation so its distribution-default configuration is never exposed. Subsequent apt requests use loopback Squid. Bootstrap/maintenance removal requires regenerating the manifest/template and reviewing service-specific update requirements; the two explicit apt hosts remain enabled by this baseline.

Squid allows only the five fixed private client addresses plus loopback, CONNECT to approved HTTPS destinations on 443, and non-CONNECT plaintext HTTP to separately approved HTTP destinations on 80; it does not intercept TLS. Domain files consume the generator's collapsed `squidHttpsDomains` and `squidHttpDomains` arrays; the combined `squidDomains` list is not used to merge protocol permissions. Deployment-specific additions are collapsed again to avoid Squid's fatal overlapping apex/subdomain entries. Firewall rules retain the original per-protocol FQDN arrays and their distinct wildcard/apex semantics. Required wildcard domains remain an explicit exception to exact-FQDN confinement. Azure Firewall Basic cannot restrict encrypted URL paths or provide DNS proxying. The pinned Ubuntu mirrors are the only direct proxy bootstrap package destinations.

Updating VM `customData` does not rerun cloud-init. For an existing proxy, generate the rendered configuration/ACL content from the updated deployment, transfer only these public configuration files over private SSH, validate with `squid -k parse`, and reload Squid. Do not rerun first-boot cloud-init or reinstall packages as a policy-update mechanism. Replacing the proxy is an alternative during an approved lab rebuild.

## Monitoring and costs

A dedicated Log Analytics workspace, Sentinel onboarding and three DCRs are created. Local Windows Security uses `Microsoft-SecurityEvent` → `SecurityEvent`; WEC `ForwardedEvents!*` uses `Microsoft-WindowsEvent` → `WindowsEvent`; selected Linux `local0` uses `Microsoft-Syslog` → `Syslog`. Source WEF subscription filters bound the forwarded-event volume. Firewall application/network diagnostics go to the workspace. Squid logs remain on its disk; central export is **not** implicitly configured. No response playbook/automation rule or tenant connector is created.

After conversion/onboarding, deploy the **separate** `arc-monitoring.bicep` using actual Arc machine names, the three `dcrIds` outputs and `proxyUrl`. Existing `Microsoft.HybridCompute/machines` must be in the current group, have system-assigned identity, and match the supplied location. AMA uses that default Arc identity and explicit anonymous application proxy settings. The three converted-target Compute VMs have **no managed identity**; their Arc representations supply the identities after real manual onboarding. No association/AMA extension is installed on the underlying Compute VMs or Win11.

Optional `budgetEmails` creates a resource-group monthly budget with an 80% actual-cost notification. Empty contacts skip the budget. The workspace daily cap can cause telemetry loss and is not a hard spend ceiling. Firewall/Bastion keep accruing charges when VMs stop.

Outputs are `vmNames`, `privateIps` (keys `management`, `l2`, `l3Windows`, `l3Linux`, `wec`, `proxy`), `proxyUrl`, `collectorFqdn` (`wec.ot.demo.test` by default), `workspaceId` (Azure resource ID), `workspaceName`, `workspaceCustomerId`, `dcrIds`, `firewallPrivateIp`, and `bastionName`.

Compilation is not Azure validation, what-if, guest configuration, deployment or end-to-end acceptance. Before a live deployment, verify image/SKU support and quotas in the chosen region, Windows 11 rights, provider registrations, role permissions, endpoint inventory, budget access and all approved tenant safeguards. Image versions default to `latest`; set `windowsServerImageVersion`, `windows11ImageVersion`, and `ubuntuImageVersion` after preflight for reproducible rebuilds. The portal UI has not been exercised against a live tenant.
