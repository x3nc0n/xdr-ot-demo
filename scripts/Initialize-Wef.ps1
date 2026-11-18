#Requires -RunAsAdministrator
<#
.SYNOPSIS
Sets up workgroup WEF with issued certificates, HTTPS and an exact source identity.
.DESCRIPTION
Run separately on Collector and Source, locally via private management. Preinstall
issued RSA leaf certificates (with private keys) in LocalMachine\My and public
root/intermediate certificates in the appropriate trust stores. Both leaves must
use the supplied immediate issuing CA. Collector requires serverAuth EKU and source
requires clientAuth EKU; CN must match its explicit FQDN. Publish working CRL/OCSP.
No CA or self-signed leaf is generated. Revocation validation is never disabled.
Prepare a dedicated LOCAL administrator account on the collector per Microsoft's
workgroup WEF recipe. Pass Get-Credential interactively as MappingCredential;
never supply a plaintext password, transcript this operation or serialize credentials.
Only the exact allowed source subject is mapped. No existing listener is deleted.
Source mode tests certificate-authenticated collector access before enabling forwarding.
Security audit policy must be configured/approved separately to emit 4624/4625.
Reference: https://learn.microsoft.com/windows/win32/wec/setting-up-a-source-initiated-subscription
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidateSet('Collector', 'Source')][string]$Mode,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{40}$')][string]$CertificateThumbprint,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{40}$')][string]$IssuerCaThumbprint,
    [Parameter(Mandatory)][ValidatePattern('^(?=.{1,253}$)[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$')][string]$CollectorFqdn,
    [ValidatePattern('^(?=.{1,253}$)[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$')][string]$SourceFqdn,
    [ValidatePattern('^(?=.{1,253}$)[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$')][string]$AllowedSourceFqdn,
    [string]$SourceAddress,
    [pscredential]$MappingCredential,
    [string]$SubscriptionTemplate = (Join-Path $PSScriptRoot '..\config\wef-subscription.xml')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Mode -eq 'Collector') {
    if (-not $AllowedSourceFqdn -or -not $SourceAddress) { throw 'Collector needs AllowedSourceFqdn and an exact source IPv4 address.' }
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($SourceAddress, [ref]$ip) -or $ip.AddressFamily -ne 'InterNetwork') { throw 'SourceAddress must be one IPv4 address, not a subnet or wildcard.' }
    $identity = $CollectorFqdn
    $eku = '1.3.6.1.5.5.7.3.1'
    $template = Get-Content -LiteralPath $SubscriptionTemplate -Raw
    if (-not $template.Contains('{{ISSUER_CA_THUMBPRINT}}') -or -not $template.Contains('{{ALLOWED_SOURCE_FQDN}}')) { throw 'Expected subscription template placeholders are missing.' }
    $rendered = $template.Replace('{{ISSUER_CA_THUMBPRINT}}', $IssuerCaThumbprint.ToUpperInvariant()).Replace('{{ALLOWED_SOURCE_FQDN}}', $AllowedSourceFqdn)
    [xml]$subscription = $rendered
} else {
    if (-not $SourceFqdn) { throw 'Source mode needs SourceFqdn matching the client certificate CN.' }
    $identity = $SourceFqdn
    $eku = '1.3.6.1.5.5.7.3.2'
}
$cert = Get-Item -LiteralPath "Cert:\LocalMachine\My\$CertificateThumbprint"
$ekuExtensions = @($cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' })
$certificateEkus = @()
if ($ekuExtensions.Count -eq 1) {
    $enhancedUsage = [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($ekuExtensions[0], $ekuExtensions[0].Critical)
    $certificateEkus = @($enhancedUsage.EnhancedKeyUsages | ForEach-Object { $_.Value })
}
if (-not $cert.HasPrivateKey -or $cert.Subject -eq $cert.Issuer -or
    $cert.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -ne $identity -or
    $eku -notin $certificateEkus) {
    throw 'Require an issued local-machine leaf, private key, exact CN/FQDN and the correct authentication EKU.'
}
$chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
$chain.ChainPolicy.RevocationMode = 'Online'
$chain.ChainPolicy.RevocationFlag = 'ExcludeRoot'
$chain.ChainPolicy.UrlRetrievalTimeout = [TimeSpan]::FromSeconds(20)
try {
    if (-not $chain.Build($cert)) { throw 'Certificate chain/revocation validation failed. Restore CA trust and CRL/OCSP reachability; do not bypass.' }
    if ($chain.ChainElements.Count -lt 2 -or $chain.ChainElements[1].Certificate.Thumbprint -ne $IssuerCaThumbprint) { throw 'IssuerCaThumbprint must identify the immediate issuing CA of the leaf.' }
    $issuerIsIntermediate = $chain.ChainElements[1].Certificate.Subject -ne $chain.ChainElements[1].Certificate.Issuer
} finally { $chain.Dispose() }
$rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
if ($rsa -is [Security.Cryptography.RSACryptoServiceProvider]) {
    $keyPath = Join-Path $env:ProgramData "Microsoft\Crypto\RSA\MachineKeys\$($rsa.CspKeyContainerInfo.UniqueKeyContainerName)"
} elseif ($rsa -is [Security.Cryptography.RSACng]) {
    $keyPath = Join-Path $env:ProgramData "Microsoft\Crypto\Keys\$($rsa.Key.UniqueName)"
} else { throw 'This script supports machine-stored RSA CSP/CNG private keys only; prepare another issued certificate.' }
$rsa.Dispose()
if (-not (Test-Path -LiteralPath $keyPath)) { throw 'Private key file not available; configure its Network Service ACL manually.' }
if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Configure $Mode WEF over issued-certificate HTTPS for exact source identity")) { return }
Set-Service WinRM -StartupType Automatic
Start-Service WinRM
Import-Module Microsoft.WSMan.Management -ErrorAction Stop
Set-Item WSMan:\localhost\Service\Auth\Certificate -Value $true
$acl = Get-Acl -LiteralPath $keyPath
$networkService = [Security.Principal.SecurityIdentifier]::new('S-1-5-20')
$rule = [Security.AccessControl.FileSystemAccessRule]::new($networkService, 'Read', 'Allow')
$acl.SetAccessRule($rule)
Set-Acl -LiteralPath $keyPath -AclObject $acl
if ($Mode -eq 'Collector') {
    $listeners = @(Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -contains 'Transport=HTTPS' })
    if ($listeners.Count) {
        if ($listeners.Count -ne 1 -or
            (Get-Item "$($listeners[0].PSPath)\CertificateThumbprint").Value -ne $CertificateThumbprint -or
            (Get-Item "$($listeners[0].PSPath)\Hostname").Value -ne $CollectorFqdn) {
            throw 'An existing HTTPS listener differs. Refusing to replace an unrelated management listener.'
        }
    } else {
        New-WSManInstance -ResourceURI winrm/config/Listener -SelectorSet @{ Address = '*'; Transport = 'HTTPS' } -ValueSet @{
            Hostname = $CollectorFqdn; CertificateThumbprint = $CertificateThumbprint
        } | Out-Null
    }
    if ($issuerIsIntermediate) {
        $schannel = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL'
        New-ItemProperty $schannel -Name ClientAuthTrustMode -Value 2 -PropertyType DWord -Force | Out-Null
    }
    $mapping = @(Get-ChildItem WSMan:\localhost\ClientCertificate | Where-Object {
        (Get-Item "$($_.PSPath)\Issuer").Value -eq $IssuerCaThumbprint -and
        (Get-Item "$($_.PSPath)\Subject").Value -eq $AllowedSourceFqdn -and
        (Get-Item "$($_.PSPath)\URI").Value -eq '*'
    })
    if (-not $mapping.Count) {
        if (-not $MappingCredential) { throw 'First run needs MappingCredential from Get-Credential for a dedicated precreated LOCAL administrator.' }
        $name = $MappingCredential.UserName
        if ($name -match '\\' -and $name.Split('\')[0] -notin '.', $env:COMPUTERNAME) { throw 'Mapping account must be local to this collector.' }
        $user = Get-LocalUser -Name ($name.Split('\')[-1])
        if (-not $user.Enabled -or $user.SID.Value -notin @((Get-LocalGroupMember -SID 'S-1-5-32-544').SID.Value)) {
            throw 'Mapping account must be an enabled dedicated local administrator per the Microsoft workgroup recipe.'
        }
        New-Item -Path WSMan:\localhost\ClientCertificate -Subject $AllowedSourceFqdn -URI '*' -Issuer $IssuerCaThumbprint -Credential $MappingCredential | Out-Null
    }
    $ruleName = 'OT-Lab-WEF-HTTPS'
    if (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue) {
        Set-NetFirewallRule -Name $ruleName -Enabled True -Profile Any -Direction Inbound -Action Allow
        Get-NetFirewallRule -Name $ruleName | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress $SourceAddress | Out-Null
        Get-NetFirewallRule -Name $ruleName | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter -Protocol TCP -LocalPort 5986 | Out-Null
    } else {
        New-NetFirewallRule -Name $ruleName -DisplayName 'OT lab WEF HTTPS exact source' -Enabled True -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5986 -RemoteAddress $SourceAddress | Out-Null
    }
    & wecutil.exe qc /q
    if ($LASTEXITCODE -ne 0) { throw 'WEC service initialization failed.' }
    & wevtutil.exe sl ForwardedEvents /e:true
    if ($LASTEXITCODE -ne 0) { throw 'ForwardedEvents enable failed.' }
    $directory = Join-Path $env:ProgramData 'OT-Lab\wef'
    New-Item $directory -ItemType Directory -Force | Out-Null
    $path = Join-Path $directory 'subscription.xml'
    $rendered | Set-Content -LiteralPath $path -Encoding UTF8
    $id = [string]$subscription.Subscription.SubscriptionId
    $ids = & wecutil.exe es
    if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate WEC subscriptions.' }
    if ($id -in $ids) {
        & wecutil.exe ss "/c:$path"
    } else {
        & wecutil.exe cs $path
    }
    if ($LASTEXITCODE -ne 0) { throw 'WEC subscription application failed.' }
    Write-Output 'Collector prepared. From the source, verify certificate-authenticated winrm/config over HTTPS; confirm WEC runtime status and actual ForwardedEvents delivery. No trust/revocation bypass configured.'
} else {
    # Verify the exact certificate mapping and server trust before enabling forwarding.
    Get-WSManInstance -ResourceURI winrm/config -ConnectionURI "https://${CollectorFqdn}:5986/wsman" -Authentication ClientCertificate -CertificateThumbprint $CertificateThumbprint | Out-Null
    $readers = Get-LocalGroup -SID 'S-1-5-32-573'
    if ('S-1-5-20' -notin @((Get-LocalGroupMember -Group $readers).SID.Value)) {
        Add-LocalGroupMember -Group $readers -Member $networkService
    }
    foreach ($channel in 'Application', 'Security') {
        $log = [Diagnostics.Eventing.Reader.EventLogConfiguration]::new($channel)
        try {
            $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($log.SecurityDescriptor)
            $hasRead = @($descriptor.DiscretionaryAcl | Where-Object {
                $_ -is [Security.AccessControl.CommonAce] -and $_.SecurityIdentifier.Value -eq 'S-1-5-20' -and
                $_.AceQualifier -eq 'AccessAllowed' -and ($_.AccessMask -band 1)
            }).Count -gt 0
            if (-not $hasRead) {
                $ace = [Security.AccessControl.CommonAce]::new('None', 'AccessAllowed', 1, $networkService, $false, $null)
                $descriptor.DiscretionaryAcl.InsertAce($descriptor.DiscretionaryAcl.Count, $ace)
                $log.SecurityDescriptor = $descriptor.GetSddlForm('All')
                $log.SaveChanges()
            }
        } finally { $log.Dispose() }
    }
    $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\EventLog\EventForwarding\SubscriptionManager'
    New-Item $policy -Force | Out-Null
    $value = "Server=HTTPS://${CollectorFqdn}:5986/wsman/SubscriptionManager/WEC,Refresh=60,IssuerCA=$IssuerCaThumbprint"
    $old = Get-ItemProperty -Path $policy -Name '1' -ErrorAction SilentlyContinue
    if ($old -and $old.'1' -ne $value) { throw 'SubscriptionManager slot 1 belongs to another configuration. Refusing overwrite.' }
    New-ItemProperty $policy -Name '1' -Value $value -PropertyType String -Force | Out-Null
    & gpupdate.exe /target:computer /force
    if ($LASTEXITCODE -ne 0) { throw 'Computer policy refresh failed.' }
    Write-Output 'Source configured. Validate ForwardingPlugin events 104/100, collector subscription runtime and forwarded heartbeat. Audit policy is an explicit manual prerequisite; AMA/DCR configuration is separate.'
}
