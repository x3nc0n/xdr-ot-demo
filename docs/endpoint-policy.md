# Endpoint policy and maintenance

`config\endpoints.json` is the reviewed, source-mapped input.
`scripts\Build-EgressPolicy.ps1` generates `config\egress.json`, consumed by Bicep
for Firewall and Squid. Rebuild ARM after changing policy.

Firewall FQDN lists preserve required apex and wildcard entries independently.
Squid lists collapse overlapping suffixes: unlike Firewall, Squid rejects
redundant parent/child `dstdomain` entries as a configuration error. Per-protocol
collapsed lists keep HTTP hosts separate from HTTPS-only destinations.

```powershell
.\scripts\Build-EgressPolicy.ps1
.\scripts\Build-Templates.ps1
```

The default enables **runtime, maintenance and bootstrap**. This permits first
installation and ongoing security updates without broad Internet access. After
staging signed installers, remove bootstrap-only rules and rebuild:

```powershell
.\scripts\Build-Templates.ps1 -Phase runtime,maintenance
```

Review the diff, run what-if, redeploy Firewall rules, and apply the matching
Squid configuration on the existing proxy. **Changing VM custom data does not
rerun cloud-init.** Copy the rendered ACL/config to the proxy through private
administration, run `sudo squid -k parse`, then `sudo squid -k reconfigure`.
Never broaden one layer while leaving the other undocumented.

## What "minimum" means here

This is a commercial-cloud, streamlined-MDE baseline, not a permanent or
exhaustive list for every tenant. Microsoft can change extension CDNs, package
redirects, certificate chains and service endpoints. Validate each agent using
its connectivity diagnostics and correlate denied hosts with documented needs
before adding a rule. A single observed IP is not a stable service allowlist.

The template adds the actual workspace ingestion endpoint and selected regional
AMA control endpoint. Do not substitute `*.blob.core.windows.net`,
`*.azurewebsites.net` or `*.microsoft.com` to make installation work.

Necessary exceptions:

| Exception | Reason / narrowing |
|---|---|
| `*.endpoint.security.microsoft.com` | Microsoft's documented streamlined MDE destination family |
| Arc HIS/guest configuration wildcards | Regional/service-selected control endpoints |
| `*.servicebus.windows.net` | Arc notification. Fetch the regional list from the Arc network-requirements documentation and pin exact required hosts if practical |
| Windows Update/CDN families | Maintenance only; remove only if an alternative tested, signed update distribution path exists |
| `www.microsoft.com` on HTTP | Microsoft PKI paths; FQDN policy allows the host, not only `/pki*`. Squid path ACLs could tighten plaintext HTTP separately |
| Ubuntu repository hosts | Package bootstrap and maintenance; proxy must install Squid before it can proxy itself |
| Certificate validation hosts | Validate actual public chains; remove unused entries, add additional required issuer endpoints narrowly |

No SmartScreen/web-browsing/live-response/MDI/Defender-for-IoT destinations are
enabled just for completeness. If those features become requirements, review
their documented dependencies separately. The Windows guest platform may have
additional activation/licensing requirements; confirm image rights and use an
approved activation path rather than opening general Internet access.

## Proxy semantics

- Anonymous explicit HTTP proxy, port 3128, restricted by client network.
- HTTPS CONNECT only to permitted destination hosts/port 443.
- Plain HTTP only on explicitly allowed host/port 80 combinations.
- No TLS inspection, no SSL bump, no authentication requirement for agents,
  no certificate-validation bypass.
- Squid suffix ACL `.example.com` includes the domain and its subdomains.
  Firewall `*.example.com` patterns have their own semantics; include the apex
  separately when actually required.
- HTTPS hostname restrictions are **not URL-path restrictions**. Firewall Basic
  does not decrypt traffic. A compromised permitted service/namespace is a
  residual risk, not eliminated by this demo.

The external [`squidmdemdi`](https://github.com/x3nc0n/squidmdemdi) project was
used only as an architectural reference. Its broad allowlist/installation
script is not executed or copied. This package supplies its own policy.

## Sources

- [MDE streamlined endpoints and common dependencies](https://learn.microsoft.com/defender-endpoint/streamlined-device-connectivity-urls-commercial)
- [Arc URLs and service-bus allowlist API](https://learn.microsoft.com/azure/azure-arc/servers/network-requirements)
- [AMA network/proxy requirements](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-network-configuration)
- [MDE Windows proxy settings](https://learn.microsoft.com/defender-endpoint/configure-proxy-internet)
- [MDE Linux static proxy](https://learn.microsoft.com/defender-endpoint/linux-static-proxy-configuration)
