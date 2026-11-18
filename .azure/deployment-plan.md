# OT telemetry lab deployment

Status: Ready for Validation

## Approved scope

Build deployable Bicep and generated ARM, a Deploy to Azure entry point,
configuration scripts and manual runbooks. No live Azure deployment or tenant
mutation is authorized by this build request.

## Architecture

Six private VMs in a hub, plant spoke and industrial-DMZ spoke. Azure Firewall
Basic controls inter-spoke and Internet traffic. Explicit Squid proxy controls
approved MDE, Arc and AMA cloud destinations. Windows 11 forwards events over
certificate-authenticated HTTPS to an Arc-managed WEC. The sensitive Windows
and Linux servers also simulate on-premises servers using evaluation-only Arc
on Azure VMs. Windows 11 retains its Azure guest agent.

## Implementation

1. Build Bicep/ARM network, compute, proxy and Sentinel resources.
2. Provide endpoint policy generation and private bootstrap instructions.
3. Provide guarded Arc, protection, WEF and AMA configuration scripts.
4. Document scoped XDR guardrails, licensing, certificate issuance and recovery.
5. Validate Bicep/ARM and scripts locally; do not claim live acceptance.

## Preparation results

The foundation and post-onboarding Arc monitoring templates compile into
self-contained ARM. Portal input contracts, focused policy/guest-precondition
tests, PowerShell lint, shell syntax and lab certificate issuance are checked
locally. Deployment entry points and ordered manual tenant steps are documented.

Validation scope is local/static only. No live what-if, paid deployment, tenant
change or guest runtime acceptance is authorized or claimed. Environment
preflight and live acceptance remain explicit operator steps.

## Deployment gates

Select subscription/tenant/region, confirm virtualization and server licensing,
review endpoint inventory and tenant policies, stage signed installers and
certificates, validate private administration, and verify response exclusions
before onboarding sensitive devices. No automated response playbooks are
created. Active AV is not an absolute availability guarantee.

## Recipe

Resource-group Bicep with PowerShell and generated self-contained ARM JSON.
The session plan contains the detailed approved design.

## All validation checks pass

| Recipe check | Result |
|---|---|
| Bicep compilation | Passed locally for foundation and Arc monitoring |
| ARM template validation in Azure | Operator execution gate; not run |
| What-if preview | Operator execution gate; not run |
| Authentication/subscription selection | Operator execution gate; no developer account assumed |
| Bicep lint | Passed locally |
| Azure Policy validation | Operator execution gate; not run |

## Role assignment verification

No custom RBAC assignments or tenant-wide grants are created. Converted Compute
VM identities are disabled; the real Arc registration supplies the identity used
by AMA. Caller permissions and Arc onboarding role are manual preflight items.
No application is granted a generic subscription data-plane role by templates.

## 7. Validation Proof

- `scripts\Build-Templates.ps1`: generated endpoint policy and compiled both ARM
  templates using Bicep v0.46.1.
- `az bicep lint --file infra\main.bicep` and the Arc entry point: passed.
- `az bicep build-params`: sample parameters compile with synthetic environment
  values; temporary parameter output removed, no credentials committed.
- Pester v5.7.1: 33 passing focused policy, portal contract, deployment approval,
  infrastructure and guest safety tests.
- PSScriptAnalyzer Error/Warning and Bash syntax checks: passed.
- Lab PKI issuance exercised with OpenSSL; server/client purpose and CRL checks
  passed; generated test private material removed.
- Actual Squid 6.14 parsing and loopback allow/deny probes exercised using
  extracted, hash-checked Ubuntu packages, without system installation. Found
  and fixed overlapping suffix ACL generation; approved HTTPS succeeded while
  other CONNECT and plaintext access to HTTPS-only destinations were denied.

Status remains Ready for Validation, not cloud-validated. The README and
operations runbook distinguish local checks from live environment acceptance.
