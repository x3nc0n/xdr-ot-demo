# Restricted-egress OT telemetry lab

An **Azure-only simulation** of on-premises OT networks: MDE to Microsoft Defender
XDR, Windows events and Linux syslog to Microsoft Sentinel, with explicit-proxy
egress through Azure Firewall Basic.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fx3nc0n%2Fxdr-ot-demo%2Fmain%2Finfra%2Fazuredeploy.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fx3nc0n%2Fxdr-ot-demo%2Fmain%2Finfra%2FcreateUiDefinition.json)

**Publishing prerequisite:** the button targets `x3nc0n/xdr-ot-demo`, branch `main`.
Publish these generated ARM/UI files there before using it. That repository was
not publicly available when this package was built. For a fork, private repository,
or another branch, use the local deployment method below, or generate a new public
link with `scripts\Get-DeployLink.ps1`. The button is not a request to deploy
anything during development.

## What gets built

| Placement | Machines / services |
|---|---|
| Management hub | Azure Firewall **Basic**, Bastion **Basic**, private Windows management host |
| Purdue L2 | Windows 11 Enterprise plant workstation |
| Purdue L3 | Windows Server sensitive-workload simulator, Ubuntu 24.04 simulator, Windows Event Collector (WEC), each isolated by subnet |
| Purdue L3.5 DMZ | Ubuntu Squid explicit proxy in a separate peered VNet |
| Cloud | Dedicated Log Analytics workspace, Sentinel and data collection rules |

There are **six private VMs**. No target VM has a public IP. Firewall and Bastion
have their required public IPs. Levels 0–1 are conceptual; no physical process or
Defender for IoT sensor is included.

The two sensitive servers and the collector are converted to Arc after private
bootstrap, with Azure guest agents disabled. **Windows 11 keeps its Azure guest
agent and does not use Arc.** Its Windows events use certificate-authenticated
HTTPS WEF to the collector, without Active Directory.

## Start here

1. Read [architecture and enforcement limits](docs/architecture.md),
   [tenant response guardrails](docs/response-guardrails.md), and the
   [endpoint policy](docs/endpoint-policy.md). Use the
   [execution preflight checklist](docs/preflight-checklist.md) for your environment.
2. Confirm Azure VM/Windows 11 virtualization rights, server MDE entitlements,
   regional availability and quota. E7 does not replace checking server licensing.
   Firewall, Bastion and Sentinel incur charges even when target VMs are stopped.
3. Use the button to deploy the **foundation**, or follow the local method below.
   Set the resource-group tag `otDemo=true` if creating the group in the portal.
4. Follow [operations](docs/operations.md) **in order** for the required tenant
   settings, private bootstrap, Arc conversion, MDE onboarding, PKI/WEF and AMA.
   The template alone does not onboard MDE or configure your tenant.
5. Run the acceptance checklist and query the expected Sentinel tables. Do not
   present a successful ARM deployment as proof of end-to-end telemetry.

## Local Bicep / ARM deployment

Author in Bicep; `infra\azuredeploy.json` is the generated, self-contained ARM
equivalent used by the button. No linked template URLs or access to this source
repository are required by the deployed infrastructure.

Prerequisites: PowerShell 7.2+, Azure CLI with Bicep, an authenticated operator,
Windows 11 Azure rights, a strong administrator password, and an SSH public key.

```powershell
.\scripts\Build-Templates.ps1
# Copy/edit infra\parameters\private.parameters.example.json to a local
# private.parameters.json (its Key Vault reference needs your vault/secret).
# Keep secrets out of git; use a Key Vault parameter reference when possible.
# The resource group must already exist for what-if:
.\scripts\Deploy-Lab.ps1 -SubscriptionId '<subscription-guid>' `
  -ResourceGroupName 'rg-ot-demo' -ParametersFile '.\private.parameters.json'

# Explicitly approved paid deployment (also prompts for confirmation):
.\scripts\Deploy-Lab.ps1 -SubscriptionId '<subscription-guid>' `
  -ResourceGroupName 'rg-ot-demo' -ParametersFile '.\private.parameters.json' `
  -Apply -LicensingAndCostReviewed
```

Alternatively use `az deployment group create --template-file infra\main.bicep`
with your parameters. Deploy Arc extensions separately with
`infra\arc-monitoring.bicep` **only after** the three Arc machine resources exist.
Guest/tenant configuration has deliberate manual approval gates.

## Safety and support boundary

**Simulation only. Never connect this lab to real control or life-safety systems.**
Arc on Azure VMs is documented for evaluation/testing, not production. There is
no fully disconnected MDE mode: cloud telemetry needs permitted egress.

Active AV remains enabled with narrowly scoped synthetic-workload exclusions.
No response playbooks are deployed. Scoped XDR automatic-response exclusions
must be verified before sensitive enrollment. **Active AV can still quarantine
or block, and privileged administrators can still issue manual responses.**
This repository does not establish a life-safety availability guarantee.

Firewall Basic and Squid restrict HTTPS destination hostnames, **not decrypted
URL paths**. Required wildcard/service endpoints and explicit bootstrap/update
exceptions are documented; there is no blanket `*.microsoft.com` allow rule.

## Validation and contribution

```powershell
.\scripts\Build-Templates.ps1
Invoke-Pester -Path .\tests -CI
Invoke-ScriptAnalyzer -Path .\scripts -Recurse -Severity Warning,Error
```

The CI workflow compiles templates, checks generated-file drift, runs focused
tests and checks shell syntax. Live Azure, OS-image, policy, MDE, Arc and Sentinel
acceptance requires your environment and is documented separately.

Do not commit onboarding bundles, certificates/private keys, parameter secrets,
CA state, or tenant evidence. No automatic publishing, live deployment, tenant
modification or teardown is performed by CI.
