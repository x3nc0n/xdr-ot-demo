#requires -Version 7.2
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]+$')][string]$CollectorFqdn,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]+$')][string]$SourceFqdn,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$OpenSslPath = 'openssl'
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Run this helper on the Windows private management host (PowerShell 7).' }
if (-not (Get-Command $OpenSslPath -ErrorAction SilentlyContinue)) { throw 'OpenSSL is required. Supply -OpenSslPath to an approved installation.' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw 'Use a new empty directory; existing CA state is never overwritten.' }
if (-not $PSCmdlet.ShouldProcess($output, 'Create encrypted lab CA, WEF certificates, PFX files and CRL')) { return }
$password = Read-Host 'Temporary CA/PFX password (store securely; never commit)' -AsSecureString
if ($password.Length -lt 12) { throw 'Use a password of at least 12 characters.' }
$credential = [Net.NetworkCredential]::new('', $password)
New-Item -ItemType Directory -Path $output | Out-Null
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
foreach ($identity in @($sid, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
}
Set-Acl -LiteralPath $output -AclObject $acl
$opensslDir = $output.Replace('\', '/')
$config = @"
[ ca ]
default_ca = lab
[ lab ]
dir = $opensslDir
database = `$dir/index.txt
new_certs_dir = `$dir/newcerts
certificate = `$dir/root.cer
private_key = `$dir/root.key
serial = `$dir/serial
crlnumber = `$dir/crlnumber
default_md = sha256
default_days = 90
default_crl_days = 30
policy = policy
unique_subject = no
[ policy ]
commonName = supplied
[ root ]
basicConstraints = critical,CA:true,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
[ collector ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:$CollectorFqdn
crlDistributionPoints = URI:http://$CollectorFqdn/pki/lab.crl
authorityKeyIdentifier = keyid,issuer
[ source ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = clientAuth
subjectAltName = DNS:$SourceFqdn
crlDistributionPoints = URI:http://$CollectorFqdn/pki/lab.crl
authorityKeyIdentifier = keyid,issuer
"@
[IO.File]::WriteAllText((Join-Path $output 'openssl.cnf'), $config)
New-Item -ItemType Directory -Path (Join-Path $output 'newcerts') | Out-Null
[IO.File]::WriteAllText((Join-Path $output 'index.txt'), '')
[IO.File]::WriteAllText((Join-Path $output 'serial'), "1000`n")
[IO.File]::WriteAllText((Join-Path $output 'crlnumber'), "1000`n")
function Invoke-OpenSsl {
    param([string[]]$Arguments)
    & $OpenSslPath @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'OpenSSL failed; inspect the retained, protected CA directory.' }
}
$previousPassword = $env:OT_LAB_PKI_PASSWORD
try {
    $env:OT_LAB_PKI_PASSWORD = $credential.Password
    Push-Location $output
    try {
        Invoke-OpenSsl @('genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:3072', '-aes-256-cbc',
            '-pass', 'env:OT_LAB_PKI_PASSWORD', '-out', 'root.key')
        Invoke-OpenSsl @('req', '-new', '-x509', '-key', 'root.key', '-passin', 'env:OT_LAB_PKI_PASSWORD',
            '-out', 'root.cer', '-days', '365', '-sha256', '-subj', '/CN=OT Lab WEF Root',
            '-config', 'openssl.cnf', '-extensions', 'root')
        foreach ($role in @('collector', 'source')) {
            $fqdn = if ($role -eq 'collector') { $CollectorFqdn } else { $SourceFqdn }
            Invoke-OpenSsl @('genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048', '-aes-256-cbc',
                '-pass', 'env:OT_LAB_PKI_PASSWORD', '-out', "$role.key")
            Invoke-OpenSsl @('req', '-new', '-key', "$role.key", '-passin', 'env:OT_LAB_PKI_PASSWORD',
                '-out', "$role.csr", '-subj', "/CN=$fqdn")
            Invoke-OpenSsl @('ca', '-batch', '-config', 'openssl.cnf', '-passin', 'env:OT_LAB_PKI_PASSWORD',
                '-extensions', $role, '-in', "$role.csr", '-out', "$role.cer", '-notext')
            Invoke-OpenSsl @('pkcs12', '-export', '-out', "$role.pfx", '-inkey', "$role.key",
                '-in', "$role.cer", '-certfile', 'root.cer', '-passin', 'env:OT_LAB_PKI_PASSWORD',
                '-passout', 'env:OT_LAB_PKI_PASSWORD')
        }
        Invoke-OpenSsl @('ca', '-gencrl', '-config', 'openssl.cnf', '-passin', 'env:OT_LAB_PKI_PASSWORD', '-out', 'lab.crl.pem')
        Invoke-OpenSsl @('crl', '-in', 'lab.crl.pem', '-outform', 'DER', '-out', 'lab.crl')
        Invoke-OpenSsl @('verify', '-CAfile', 'root.cer', 'collector.cer', 'source.cer')
    } finally { Pop-Location }
} finally {
    $env:OT_LAB_PKI_PASSWORD = $previousPassword
    $credential = $null
}
Write-Output 'Created lab PKI. Distribute only root.cer, lab.crl and each machine-specific PFX to the appropriate host.'
Write-Output 'Keep root.key and CA state protected here; renew the CRL before its 30-day expiry. See docs\operations.md.'
