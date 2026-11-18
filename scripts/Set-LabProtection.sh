#!/usr/bin/env bash
# Configure installed MDE before MANUAL Linux onboarding; never execute downloaded scripts.
# Obtain the Linux onboarding .py from your tenant portal, verify an independently
# trusted SHA256 and inspect it; follow the portal's sudo python3 <package.py> step.
# No onboarding material or secrets are read here.
set -euo pipefail
die() { printf '%s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'HELP'
Configure installed Linux MDE BEFORE manual tenant onboarding:
  sudo bash scripts/Set-LabProtection.sh --proxy-url http://proxy.example.test:3128 \
    --device-tag OT-Lab-Sensitive --response-guardrails-verified
The acknowledgement requires verified scoped tenant/canary response guardrails.
Configures persistent explicit proxy, active real-time AV, EPP-only sample-file
exclusion and lab tag. Refuses to overwrite a different managed enterprise policy.
Does NOT install MDE or execute onboarding. Obtain, inspect and independently
hash-verify the tenant Linux onboarding .py and follow the portal's manual steps.
HELP
}
proxy= tag= guard=
while (($#)); do
    case "$1" in
        --help|-h) usage; exit 0;;
        --proxy-url) proxy="${2:?}"; shift 2;;
        --device-tag) tag="${2:?}"; shift 2;;
        --response-guardrails-verified) guard=yes; shift;;
        *) die "Unknown argument: $1";;
    esac
done
[[ $EUID == 0 && $guard == yes ]] || die 'Root and --response-guardrails-verified required. Verify initial enrollment/canary and tenant controls first.'
[[ $proxy =~ ^http://[a-zA-Z0-9.-]+:[0-9]+/?$ && $tag =~ ^[a-zA-Z0-9_-]{1,64}$ ]] || die 'Require anonymous http://host:port proxy and safe lab device tag.'
command -v mdatp >/dev/null || die 'Stage and install the verified Microsoft MDE package first.'
command -v python3 >/dev/null || die 'python3 is required.'
# Existing managed policy is authoritative: only an identical lab profile is reusable.
managed=/etc/opt/microsoft/mdatp/managed/mdatp_managed.json
profile() {
python3 - "$proxy" "$managed" "$1" <<'PY'
import json, os, sys
profile = {
    "antivirusEngine": {"enforcementLevel": "real_time"},
    "exclusionSettings": {
        "exclusions": [{"$type": "excludedPath", "isDirectory": False,
                        "path": "/var/lib/ot-lab/sample-state.json", "scopes": ["epp"]}]
    },
    "cloudService": {"enabled": True, "proxy": sys.argv[1]}
}
if os.path.exists(sys.argv[2]):
    with open(sys.argv[2], encoding="utf-8") as f:
        if json.load(f) != profile:
            sys.exit("Managed MDE policy differs; merge with its policy owner, never overwrite.")
    print("existing")
else:
    if sys.argv[3] == "write":
        with open(sys.argv[2], "x", encoding="utf-8") as f:
            json.dump(profile, f, indent=2)
            f.write("\n")
        os.chmod(sys.argv[2], 0o644)
    print("new")
PY
}
state="$(profile check)"
if [[ $state == new ]]; then
    mdatp config proxy set --value "${proxy%/}"
    mdatp config passive-mode --value disabled
    mdatp config real-time-protection --value enabled
    install -d -m 0755 "$(dirname "$managed")"
    profile write >/dev/null
fi
mdatp edr tag set --name GROUP --value "$tag"
mdatp health --field real_time_protection_enabled
mdatp health --field passive_mode_enabled
printf '%s\n' 'Local policy applied; onboarding NOT executed. Verify mdatp health, proxy, exclusions and scoped tenant group before/after manual verified Linux .py onboarding. Active AV residual risk remains.'
