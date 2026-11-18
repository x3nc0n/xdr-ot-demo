# Required tenant-side response guardrails

**Complete before onboarding sensitive devices.** These settings are deliberately
not implemented as undocumented ARM resources or broad tenant API writes.
Record screenshots/read-backs in protected operator evidence, not source control.

## Before enrollment

1. Confirm the Azure subscription and M365 tenant relationship and server
   licenses. Export the existing device-group ordering/membership, automated
   response settings, relevant endpoint policies, Sentinel automation and
   Defender for Cloud auto-provisioning policies.
2. Create uniquely scoped lab device groups. Use exact deployment-derived
   machine names and supported pre-onboarding tags. Distinguish sensitive
   servers, workstation and infrastructure. Preview group matching so no
   production endpoint is captured.
3. Under the Defender portal's current **Automated responses / Devices / Device
   groups** settings, set the lab groups to **No automated response**. Microsoft's
   [attack-disruption exclusion guidance](https://learn.microsoft.com/defender-xdr/automatic-attack-disruption-exclusions)
   describes device-group exclusions for mission-critical systems.
4. Inspect the currently available scoped attack-disruption controls. If the
   device-group exclusion is insufficient for the tenant's current controls,
   obtain approval for the tag-policy application feature (documented as
   Preview), disable the applicable containment/isolation controls for the lab,
   and read back effective scope. **If a supported scoped exclusion cannot be
   established, stop. Do not disable disruption tenant-wide.**
5. Inspect current AV, EDR block/remediation and endpoint-management policies.
   Do not assume AIR scope governs every AV behavior. Linux does not acquire
   Windows AIR support by analogy; Linux manual isolation still exists.
6. Validate first-enrollment group assignment on a **disposable non-sensitive
   canary** before the sensitive servers. Prove there is no default-group
   automated-response window. If that cannot be established, do not onboard the
   sensitive servers.
7. Check Defender for Cloud/Policy will not re-add Azure VM extensions or
   auto-onboard both the Compute and Arc representations. Resolve conflicts
   with the owner; do not silently disable subscription-level protection.
8. Use least-privilege demo operator accounts without machine-response,
   isolation, live-response or remediation permissions. Privileged tenant
   administrators remain able to act; this is not an immutable interlock.

The protection scripts require an explicit guardrails acknowledgment. That
switch is **an operator assertion**, not programmatic proof of tenant state.

## Sentinel / XDR integration

The template enables a dedicated lab Sentinel workspace, but does **not** link
your existing XDR tenant or create response playbooks.

In the Defender portal:

1. Have the tenant/workspace owner review the current Microsoft Defender XDR
   connector and any existing connected workspaces.
2. Approve onboarding/linking this workspace, including incident synchronization
   semantics and existing-primary-workspace constraints.
3. Enable only required incident/alert integration. Raw advanced hunting table
   ingestion is opt-in and separately priced; do not enable all tables.
4. Inspect existing Sentinel automation rules, Logic Apps and external SOAR
   integrations for actions that could affect the lab. Do not deploy response
   rules/playbooks, and do not give new Logic Apps MDE machine-action permissions.
5. Verify non-demo tenant settings and production group membership remain
   unchanged after setup.

See [Defender XDR connector guidance](https://learn.microsoft.com/azure/sentinel/connect-microsoft-365-defender).
Use the current Defender portal rather than depending on retiring Azure-portal
Sentinel workflows.

## What is and is not demonstrated

Read back group membership, effective settings and Action Center records. Use
benign heartbeat/event-generation scenarios. A harmless alert with no response
does **not** prove every disruption control is disabled.

Active Windows/Linux antivirus remains enabled. Narrow file exclusions reduce
synthetic-workload interference but do not prevent all file blocking, quarantine,
policy changes or operator mistakes. Never test malware, EICAR, attack chains or
automatic containment on the sensitive targets to "prove" life-safety behavior.
No real life-safety system belongs in this lab.
