# Architecture and trust boundaries

## Traffic paths

```text
Operator browser -> Bastion -> private management host -> approved RDP/SSH

L2 Win11 ----+
L3 Windows -+-> Firewall (private routing) -> Squid L3.5
L3 Linux ---+                                  |
L3 WEC -----+                                  +-> Firewall (FQDN rules) -> approved cloud

Win11 -> Firewall -> WEC:5986 -> AMA -> Squid -> Firewall -> Log Analytics
Windows Server Security -> Arc AMA -> Squid -> Firewall -> SecurityEvent
Linux local0 syslog -> Arc AMA -> Squid -> Firewall -> Syslog
MDE sensor -> Squid -> Firewall -> MDE cloud -> XDR -> approved Sentinel integration
```

Plant/DMZ spokes peer only with the hub. Peering is **not transitive**. Specific
UDRs and symmetric return routes direct private inter-spoke sessions through the
firewall. More-specific plant routes enforce the L2-to-WEC boundary even though
those subnets share a VNet. Squid terminates the client TCP session and creates a
separate outbound session; verify both in firewall diagnostics.

Targets have no public NIC IP, NAT Gateway or direct egress permission. NSG
rules deny broad VNet connectivity before Azure's default allow rules. The
proxy is not an unrestricted tunnel: clients and destination ports/hosts are
restricted. Proxy egress is filtered again by Firewall application rules, not a
network rule allowing all TCP 443.

Azure platform dependencies are different from public application egress.
DNS/DHCP/time/guest-agent platform endpoints must be handled deliberately.
The host IMDS blocks apply to the Arc-converted servers, not Win11 and not all
Azure platform IPs. Azure-provided DNS is not a DNS-tunneling prevention control.
Firewall Basic cannot act as a DNS proxy.

## Resource identity and management

For the converted machines:

- `Microsoft.Compute/virtualMachines` remains the virtual hardware resource.
- `Microsoft.HybridCompute/machines` becomes the simulated on-premises guest
  management/AMA identity. It is created by actual Arc onboarding, not by
  fabricating a disconnected resource in ARM.
- Remove VM extensions **before** disabling the Azure guest agent. AMA is
  subsequently installed as an Arc extension, not a VM extension.
- Arc's managed identity must not be confused with the underlying Azure VM
  managed identity. DCR associations point at the Arc resource.

`MSFT_ARC_TEST` and persistent blocks for IMDS `.253` and `.254` make this a
documented lab exception. This is not a production Arc-on-Azure architecture.
Converting a VM removes ordinary extension-based recovery/Run Command as a
reliable fallback. Bastion/private administrator access and a rebuild/disk-repair
procedure are required first.

## Deliberate limitations

- **Active AV is not passive monitoring.** Scoped response exclusions do not
  guarantee that file blocking or quarantine cannot affect a process.
- Arc, AMA and MDE have separate proxy settings. One agent's setting is not
  inherited reliably by another.
- Private Link is not part of this initial build and would not privatize MDE
  or all Arc dependencies.
- No AD domain is silently added. WEF needs PKI issuance, trust, permissions
  and reachable certificate revocation data.
- Win11 uses WEF, not AMA or Arc. Forwarded Security events land in
  `WindowsEvent`, unlike server-local `SecurityEvent`.
- Azure Firewall Basic requires a dedicated management NIC/subnet/public IP.
  Its platform management traffic is separate from application allow rules.
- The lab PKI's root private key belongs only in protected operator storage.
  Certificates and CRLs expire; expiry causes collection failure, not a reason
  to disable certificate validation.

## Authoritative references

- [Arc-on-Azure evaluation procedure](https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine)
- [Arc network requirements](https://learn.microsoft.com/azure/azure-arc/servers/network-requirements)
- [Firewall SKU differences](https://learn.microsoft.com/azure/firewall/features-by-sku)
- [Bastion NSG requirements](https://learn.microsoft.com/azure/bastion/bastion-nsg)
- [Sentinel Windows collection and table behavior](https://learn.microsoft.com/azure/sentinel/connect-services-windows-based)
