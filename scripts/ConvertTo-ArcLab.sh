#!/usr/bin/env bash
# Evaluation only. Run locally over private SSH, NEVER Azure Run Command.
# SHA256 must be obtained independently from an authenticated Microsoft package source.
# Afterwards, manually run (interactive authentication, no service-principal secret):
# sudo azcmagent connect --tenant-id <tenant> --subscription-id <subscription> --resource-group <group> --location <region> --use-device-code
set -euo pipefail
die() { printf '%s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'HELP'
Evaluation-only Azure-to-Arc preparation for Ubuntu 24.04 x64. Does not connect.
Run over tested private SSH after removing Compute extensions and preventing redeployment:
  sudo bash scripts/ConvertTo-ArcLab.sh --role linuxUbuntu24 \
    --proxy-url http://proxy.example.test:3128 --installer /opt/ot-demo/staged/azcmagent.deb \
    --sha256 <independently-trusted-SHA256> --extensions-removed-verified \
    --policy-redeployment-prevented --private-management-verified
Stage nftables, rsyslog, curl, python3 and all Arc dependencies before conversion.
After reboot validation, connect manually using azcmagent connect --use-device-code
with explicit --tenant-id, --subscription-id, --resource-group and --location.
No service-principal secrets. Existing Arc identity is preserved.
HELP
}
role= proxy= installer= sha= extensions= policy= management=
while (($#)); do
    case "$1" in
        --help|-h) usage; exit 0;;
        --role) role="${2:?}"; shift 2;;
        --proxy-url) proxy="${2:?}"; shift 2;;
        --installer) installer="${2:?}"; shift 2;;
        --sha256) sha="${2:?}"; shift 2;;
        --extensions-removed-verified) extensions=yes; shift;;
        --policy-redeployment-prevented) policy=yes; shift;;
        --private-management-verified) management=yes; shift;;
        *) die "Unknown argument: $1";;
    esac
done
[[ $EUID == 0 ]] || die 'Run as root over private SSH.'
if command -v azcmagent >/dev/null; then
    command -v python3 >/dev/null || die 'python3 is required to inspect existing Arc identity.'
    current="$(azcmagent show --json)" || die 'Cannot inspect Arc; refusing conversion.'
    if printf '%s' "$current" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("resourceId") else 1)'; then
        printf '%s\n' 'Arc identity already exists; no conversion or reconnection.'
        exit 0
    fi
fi
[[ $role == linuxUbuntu24 && $extensions == yes && $policy == yes && $management == yes ]] ||
    die 'Require linuxUbuntu24 role and all three prerequisite acknowledgements.'
# shellcheck source=/dev/null
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 && $(uname -m) == x86_64 ]] || die 'Only Ubuntu 24.04 x64 is supported.'
[[ $proxy =~ ^http://[a-zA-Z0-9.-]+:[0-9]+/?$ ]] || die 'Use anonymous http://host:port proxy.'
[[ -f $installer && $installer == *.deb && $sha =~ ^[a-fA-F0-9]{64}$ ]] || die 'Require a staged .deb and trusted SHA256.'
actual="$(sha256sum -- "$installer")"; actual="${actual%% *}"
[[ ${actual,,} == ${sha,,} ]] || die 'Installer SHA256 mismatch.'
for tool in nft systemctl dpkg dpkg-deb python3 rsyslogd curl; do
    command -v "$tool" >/dev/null || die "Missing $tool. Before conversion, stage its packages or use the approved bootstrap allowlist with: sudo apt-get -o Acquire::http::Proxy=$proxy -o Acquire::https::Proxy=$proxy install nftables rsyslog curl python3"
done
systemctl is-active --quiet rsyslog.service ||
    die 'Start the staged syslog dependency before conversion: sudo systemctl enable --now rsyslog.service'
[[ $(dpkg-deb --field "$installer" Package) == azcmagent && $(dpkg-deb --field "$installer" Architecture) == amd64 ]] ||
    die 'Expected Microsoft azcmagent amd64 package.'
dpkg --dry-run --install "$installer" >/dev/null || die 'Resolve the staged package dependencies before disabling Azure management.'
services=()
for service in walinuxagent.service waagent.service; do
    if systemctl cat "$service" >/dev/null 2>&1; then services+=("$service"); fi
done
((${#services[@]})) || die 'No installed Azure guest-agent service found; inspect manually.'
install -d -m 0755 /etc/ot-demo /etc/systemd/system.conf.d
cat > /etc/ot-demo/arc-imds.nft <<'NFT'
table inet ot_arc_lab {
    chain output {
        type filter hook output priority -10; policy accept;
        ip daddr { 169.254.169.253, 169.254.169.254 } drop
    }
}
NFT
# Check the dedicated rules before disabling the agent; never flush unrelated rules.
if ! nft list table inet ot_arc_lab >/dev/null 2>&1; then nft --check --file /etc/ot-demo/arc-imds.nft; fi
cat > /etc/systemd/system/ot-arc-imds.service <<'UNIT'
[Unit]
Description=OT lab evaluation IMDS blocks (dedicated nftables table only)
After=local-fs.target nftables.service
Before=himdsd.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/usr/sbin/nft delete table inet ot_arc_lab
ExecStart=/usr/sbin/nft --file /etc/ot-demo/arc-imds.nft
ExecReload=/bin/sh -c '/usr/sbin/nft delete table inet ot_arc_lab && /usr/sbin/nft --file /etc/ot-demo/arc-imds.nft'
[Install]
WantedBy=multi-user.target
UNIT
cat > /etc/systemd/system.conf.d/ot-arc-evaluation.conf <<'UNIT'
[Manager]
DefaultEnvironment=MSFT_ARC_TEST=true
UNIT
printf '%s\n' 'export MSFT_ARC_TEST=true' > /etc/profile.d/ot-arc-evaluation.sh
export MSFT_ARC_TEST=true
systemctl set-environment MSFT_ARC_TEST=true
systemctl daemon-reload
systemctl enable ot-arc-imds.service
systemctl restart ot-arc-imds.service
nft list table inet ot_arc_lab >/dev/null
for service in "${services[@]}"; do systemctl disable --now "$service"; done
if ! command -v azcmagent >/dev/null; then dpkg --install "$installer"; fi
azcmagent config set proxy.url "${proxy%/}"
printf '%s\n' 'Prepared, NOT connected. Reboot and verify guest-agent/IMDS persistence, then use manual device-code connect shown in script header. Configure AMA proxy separately.'
