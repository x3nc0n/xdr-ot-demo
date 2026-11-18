BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $script:arcText = Get-Content (Join-Path $root 'scripts\ConvertTo-ArcLab.ps1') -Raw
    $script:wefText = Get-Content (Join-Path $root 'scripts\Initialize-Wef.ps1') -Raw
    $script:arc = [scriptblock]::Create(($arcText -replace '(?im)^#Requires -RunAsAdministrator\r?\n', ''))
    $script:wef = [scriptblock]::Create(($wefText -replace '(?im)^#Requires -RunAsAdministrator\r?\n', ''))
    $script:arcParameters = @{
        Role = 'windows2022'; ProxyUrl = 'http://proxy.ot.demo.test:3128'
        InstallerPath = 'C:\staged\Arc.msi'; InstallerSha256 = 'A' * 64
        TrustedSignerThumbprint = 'B' * 40
        ExtensionsRemovedVerified = $true; PolicyRedeploymentPrevented = $true
        PrivateManagementVerified = $true; WhatIf = $true; Confirm = $false
    }
    $script:wefParameters = @{
        Mode = 'Source'; CertificateThumbprint = 'C' * 40; IssuerCaThumbprint = 'D' * 40
        CollectorFqdn = 'wec.ot.demo.test'; SourceFqdn = 'source.ot.demo.test'
        SubscriptionTemplate = (Join-Path $root 'config\wef-subscription.xml')
        WhatIf = $true; Confirm = $false
    }
    function Get-GuestCommandBlock([string]$Text, [string]$Name, [string]$Contains) {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
        $nodes = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq $Name -and $node.Extent.Text.Contains($Contains)
        }, $true))
        if ($nodes.Count -ne 1) { throw "Expected one $Name command matching $Contains, found $($nodes.Count)" }
        [scriptblock]::Create($nodes[0].Extent.Text)
    }
}

Describe 'Arc preflight stops before ShouldProcess and any mutation' {
    BeforeEach {
        Mock Test-Path { $false }
        Mock Get-CimInstance { [pscustomobject]@{ProductType=3;BuildNumber='20348'} }
        Mock Get-Item { [pscustomobject]@{Extension='.msi';PSIsContainer=$false;FullName='C:\staged\Arc.msi'} }
        Mock Get-FileHash { [pscustomobject]@{Hash='A'*64} }
        Mock Get-AuthenticodeSignature { [pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Thumbprint='B'*40;Subject='CN=Microsoft, O=Microsoft Corporation'}} }
        Mock Get-Service { [pscustomobject]@{Name='WindowsAzureGuestAgent'} }
        Mock Get-NetFirewallProfile { [pscustomobject]@{Enabled=$true} }
        Mock Stop-Service { throw 'UNEXPECTED MUTATION' }
        Mock Set-Service { throw 'UNEXPECTED MUTATION' }
        Mock Start-Process { throw 'UNEXPECTED MUTATION' }
    }
    It 'rejects unverified extension/private management prerequisites' {
        $p = $arcParameters.Clone(); $p.PrivateManagementVerified = $false
        { & $arc @p } | Should -Throw '*verified Compute extension removal*'
        Should -Invoke Get-CimInstance -Times 0
    }
    It 'refuses a Windows client even with all acknowledgement switches' {
        Mock Get-CimInstance { [pscustomobject]@{ProductType=1;BuildNumber='26100'} }
        { & $arc @arcParameters } | Should -Throw '*never run on Windows 11*'
        Should -Invoke Get-Item -Times 0
    }
    It 'rejects an absent staged installer before confirmation' {
        Mock Get-Item { throw [IO.FileNotFoundException]::new('Staged installer missing') }
        { & $arc @arcParameters } | Should -Throw '*Staged installer missing*'
        Should -Invoke Get-FileHash -Times 0
    }
    It 'rejects a missing SHA256 in parameter binding' {
        $p = $arcParameters.Clone(); $p.InstallerSha256 = ''
        { & $arc @p } | Should -Throw
        Should -Invoke Get-CimInstance -Times 0
    }
    It 'rejects a mismatching SHA256 before signature checks' {
        Mock Get-FileHash { [pscustomobject]@{Hash='E'*64} }
        { & $arc @arcParameters } | Should -Throw '*SHA256 mismatch*'
        Should -Invoke Get-AuthenticodeSignature -Times 0
    }
    It 'rejects denied installer access before confirmation' {
        Mock Get-Item { throw [UnauthorizedAccessException]::new('Installer access denied') }
        { & $arc @arcParameters } | Should -Throw '*Installer access denied*'
    }
    It 'rejects an invalid installer signature' {
        Mock Get-AuthenticodeSignature { [pscustomobject]@{Status='NotSigned';SignerCertificate=$null} }
        { & $arc @arcParameters } | Should -Throw '*signature verification failed*'
    }
    It 'WhatIf returns only after all successful preconditions' {
        & $arc @arcParameters
        Should -Invoke Get-NetFirewallProfile -Times 1
        Should -Invoke Stop-Service -Times 0
        Should -Invoke Set-Service -Times 0
        Should -Invoke Start-Process -Times 0
    }
}

Describe 'WEF trust and certificate permissions fail closed' {
    BeforeEach {
        Mock Set-Service { throw 'UNEXPECTED MUTATION' }
        Mock Start-Service { throw 'UNEXPECTED MUTATION' }
        Mock Set-Acl { throw 'UNEXPECTED MUTATION' }
    }
    It 'rejects missing certificate permissions before confirmation or service mutation' {
        Mock Get-Item { throw [UnauthorizedAccessException]::new('Certificate access denied') }
        { & $wef @wefParameters } | Should -Throw '*Certificate access denied*'
        Should -Invoke Set-Service -Times 0
        Should -Invoke Start-Service -Times 0
        Should -Invoke Set-Acl -Times 0
    }
    It 'rejects an untrusted issued leaf using the real online-revocation chain builder' {
        $rootKey = [Security.Cryptography.RSA]::Create(2048)
        $leafKey = [Security.Cryptography.RSA]::Create(2048)
        $rootCert = $null; $leafCert = $null; $publicLeaf = $null
        try {
            $rootRequest = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=EphemeralTestCA', $rootKey, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $rootRequest.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true,$false,0,$true))
            $rootCert = $rootRequest.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1),[DateTimeOffset]::UtcNow.AddMinutes(10))
            $leafRequest = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=source.ot.demo.test', $leafKey, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $oids = [Security.Cryptography.OidCollection]::new()
            [void]$oids.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.2'))
            $leafRequest.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($oids,$true))
            $publicLeaf = $leafRequest.Create($rootCert,[DateTimeOffset]::UtcNow.AddSeconds(-30),[DateTimeOffset]::UtcNow.AddMinutes(5),[byte[]](1,2,3,4))
            $leafCert = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey($publicLeaf,$leafKey)
            $script:ephemeralLeaf = $leafCert
            Mock Get-Item { $script:ephemeralLeaf }
            { & $wef @wefParameters } | Should -Throw '*chain/revocation validation failed*'
            Should -Invoke Set-Service -Times 0
            Should -Invoke Set-Acl -Times 0
        } finally {
            foreach ($item in @($leafCert,$publicLeaf,$rootCert,$leafKey,$rootKey)) { if ($item) { $item.Dispose() } }
        }
    }
}

Describe 'WEF executed configuration statements preserve exact boundaries' {
    It 'writes source policy in the supported SubscriptionManager registry key' {
        Mock New-Item {}
        Mock New-ItemProperty {}
        Mock Get-ItemProperty { $null }
        $start = $wefText.IndexOf("    `$policy = 'HKLM:")
        $end = $wefText.IndexOf('    & gpupdate.exe', $start)
        $code = [scriptblock]::Create($wefText.Substring($start, $end-$start))
        $script:CollectorFqdn='wec.ot.demo.test'; $script:IssuerCaThumbprint='D'*40
        & $code
        Should -Invoke New-ItemProperty -Times 1 -ParameterFilter {
            $Path -eq 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\EventLog\EventForwarding\SubscriptionManager' -and
            $Name -eq '1' -and $PropertyType -eq 'String' -and
            $Value -eq "Server=HTTPS://wec.ot.demo.test:5986/wsman/SubscriptionManager/WEC,Refresh=60,IssuerCA=$('D'*40)"
        }
    }
    It 'tests the authenticated winrm/config resource with ClientCertificate and no validation bypass' {
        Mock Get-WSManInstance {}
        $script:CollectorFqdn='wec.ot.demo.test';$script:CertificateThumbprint='C'*40
        & (Get-GuestCommandBlock $wefText 'Get-WSManInstance' '-ConnectionURI')
        Should -Invoke Get-WSManInstance -Times 1 -ParameterFilter {
            $ResourceURI -eq 'winrm/config' -and
            $ConnectionURI -eq 'https://wec.ot.demo.test:5986/wsman' -and
            $Authentication -eq 'ClientCertificate' -and $CertificateThumbprint -eq ('C'*40)
        }
    }
    It 'uses the supported certificate mapping provider with exact subject and secure credential input' {
        $command = Get-GuestCommandBlock $wefText 'New-Item' '-Path WSMan:\localhost\ClientCertificate'
        $script:AllowedSourceFqdn = 'source.ot.demo.test'; $script:IssuerCaThumbprint = 'D'*40
        $script:MappingCredential = [pscredential]::new('wec\ephemeral-test', [securestring]::new())
        $mapping = & {
            function New-Item {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification='Isolated no-I/O test double for WSMan provider dynamic parameters.')]
                [CmdletBinding(SupportsShouldProcess)]
                param($Path,$Subject,$URI,$Issuer,[pscredential]$Credential)
                if ($PSCmdlet.ShouldProcess('test double', 'Capture parameters without I/O')) {
                    [pscustomobject]@{Path=$Path;Subject=$Subject;URI=$URI;Issuer=$Issuer;Credential=$Credential}
                }
            }
            & $command
        }
        $mapping.Path | Should -Be 'WSMan:\localhost\ClientCertificate'
        $mapping.Subject | Should -Be 'source.ot.demo.test'
        $mapping.URI | Should -Be '*'
        $mapping.Issuer | Should -Be ('D'*40)
        $mapping.Credential | Should -Be $MappingCredential
    }
    It 'opens only TCP5986 to the exact source address in its collector rule' {
        Mock Get-NetFirewallRule { $null }
        Mock New-NetFirewallRule {}
        $ast=[System.Management.Automation.Language.Parser]::ParseInput($wefText,[ref]$null,[ref]$null)
        $node=$ast.Find({param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq 'Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue'},$true)
        $node | Should -Not -BeNullOrEmpty
        $script:ruleName='OT-Lab-WEF-HTTPS';$script:SourceAddress='10.1.2.4'
        & ([scriptblock]::Create($node.Extent.Text))
        Should -Invoke New-NetFirewallRule -Times 1 -ParameterFilter {
            $Name -eq 'OT-Lab-WEF-HTTPS' -and $Direction -eq 'Inbound' -and $Protocol -eq 'TCP' -and
            $LocalPort -eq 5986 -and $RemoteAddress -eq '10.1.2.4'
        }
    }
    It 'retains online revocation and contains no token-filter/trust/revocation bypass' {
        $wefText | Should -Match '\.RevocationMode = ''Online'''
        $wefText | Should -Match '\.RevocationFlag = ''ExcludeRoot'''
        $wefText | Should -Not -Match 'LocalAccountTokenFilterPolicy|SkipCACheck|SkipCNCheck|SkipRevocationCheck|TrustedHosts|RevocationMode = ''NoCheck'''
    }
}
