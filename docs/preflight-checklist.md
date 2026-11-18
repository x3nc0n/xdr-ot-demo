# Execution preflight record

Complete this outside source control using environment-specific evidence. These
are deployment/operator decisions, not values guessed by the templates.

| Decision / evidence | Required outcome |
|---|---|
| Subscription, Entra tenant, XDR tenant | Correct relationship and operator RBAC confirmed |
| Region, workspace geography | East US 2 or explicitly chosen alternative; residency approved |
| VM images and quota | Image URNs/versions exist and six VMs plus Firewall/Bastion are permitted |
| Windows 11 | Azure virtualization rights and supported Enterprise image confirmed |
| Server MDE | Separate entitlement confirmed for each server actually onboarded |
| Cost | Firewall/Bastion steady-state, compute/disks, Sentinel ingestion/retention and protection reviewed |
| Resource group | Dedicated to lab; `otDemo=true`; no shared resources |
| Network ranges | Default address plan does not overlap existing peered networks |
| Endpoint policy | Commercial cloud, streamlined MDE, exact workspace/regional endpoints and current certificate chains reviewed |
| Proxy bootstrap | Approved Ubuntu hosts/ports; installer hash/signature and redirects validated |
| Public access | No public IP on target/support NICs, NAT Gateway or alternate egress |
| Private management | Bastion to management host and RDP/SSH to targets works before conversion |
| Azure guest policies | No automatic reinstall of Compute extensions or duplicate MDE provisioning |
| Response controls | Lab device groups/exclusions preconfigured and effective |
| Canary | First-enrollment policy window verified on a disposable non-sensitive machine |
| Existing tenant automation | No Sentinel/SOAR/third-party responder will act on the sensitive targets |
| Active AV residual risk | Accepted only for synthetic workload; no real control systems attached |
| Arc conversion | Extensions removed, operator access verified, supported signed package staged |
| PKI/WEF | CA state protected, correct leaf EKUs/SANs, CRL reachable and renewed before expiry |
| AMA/connector | Arc identity/extension and expected Sentinel table mapping confirmed |
| Recovery | Offline repair/clean rebuild/offboarding procedure ready |
| Approval | Named environment owner approves paid deployment and tenant-scoped actions |

No values from a developer's currently logged-in Azure CLI account are embedded
into the templates. Do not copy subscription IDs or secrets from another user's
session or silently treat their default subscription as authorization.
