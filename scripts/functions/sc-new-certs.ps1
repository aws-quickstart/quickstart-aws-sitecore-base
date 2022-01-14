#  Copyright 2016 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
#  This file is licensed to you under the AWS Customer Agreement (the "License").
#  You may not use this file except in compliance with the License.
#  A copy of the License is located at http://aws.amazon.com/agreement/ .
#  This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied.
#  See the License for the specific language governing permissions and limitations under the License.

[CmdletBinding()]
param (
    [string]$SCQSPrefix
)
#Certificate Requirments
$RootFriendlyName = (Get-SSMParameter -Name "/$SCQSPrefix/cert/root/friendlyname").Value
$RootDNSNames = ((Get-SSMParameter -Name "/$SCQSPrefix/cert/root/dnsnames").Value).Split(",").Trim()
$InstanceFriendlyName = (Get-SSMParameter -Name "/$SCQSPrefix/cert/instance/friendlyname").Value
$InstanceDNSNames = ((Get-SSMParameter -Name "/$SCQSPrefix/cert/instance/dnsnames").Value).Split(",").Trim()
$XConnectFriendlyName = (Get-SSMParameter -Name "/$SCQSPrefix/cert/xconnect/friendlyname").Value
$xConnectDNSNames = ((Get-SSMParameter -Name "/$SCQSPrefix/cert/xconnect/dnsnames").Value).Split(",").Trim()
$CertStoreLocation = (Get-SSMParameter -Name "/$SCQSPrefix/cert/storelocation").Value
$RawPassword = (ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId "sitecore-quickstart-$SCQSPrefix-certpass").SecretString).password
$ExportPassword = ConvertTo-SecureString $RawPassword -AsPlainText -Force
$ExportPath = (Get-SSMParameter -Name "/$SCQSPrefix/user/localresourcespath").Value
$ExportRootCertName = (Get-SSMParameter -Name "/$SCQSPrefix/cert/root/exportname").Value
$ExportInstanceCertName = (Get-SSMParameter -Name "/$SCQSPrefix/cert/instance/exportname").Value
$ExportXConnectCertName = (Get-SSMParameter -Name "/$SCQSPrefix/cert/xconnect/exportname").Value
$S3BucketName = (Get-SSMParameter -Name "/$SCQSPrefix/user/s3bucket/name").Value
$S3BucketCertificatePrefix = (Get-SSMParameter -Name "/$SCQSPrefix/user/s3bucket/certificateprefix").Value

$logGroupName = "$SCQSPrefix-ssm-bootstrap"
$logStreamName = "CertificateCreation" + (Get-Date (Get-Date).ToUniversalTime() -Format "MM-dd-yyyy" )

#Create new certificates
function NewCertificate {
    param(
        [string]$FriendlyName,
        [string[]]$DNSNames,
        [ValidateSet("LocalMachine", "CurrentUser")]
        [string]$CertStoreLocation = "LocalMachine",
        [ValidateScript( { $_.HasPrivateKey })]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Signer
    )

    # DCOM errors in System Logs are by design.
    # https://support.microsoft.com/en-gb/help/4022522/dcom-event-id-10016-is-logged-in-windows-10-and-windows-server-2016

    $date = Get-Date
    $certificateLocation = "Cert:\\$CertStoreLocation\My"
    $rootCertificateLocation = "Cert:\\$CertStoreLocation\Root"

    # Certificate Creation Location.
    $location = @{ }
    if ($CertStoreLocation -eq "LocalMachine") {
        $location.MachineContext = $true
        $location.Value = 2 # Machine Context
    }
    else {
        $location.MachineContext = $false
        $location.Value = 1 # User Context
    }

    # RSA Object
    $rsa = New-Object -ComObject X509Enrollment.CObjectId
    $rsa.InitializeFromValue(([Security.Cryptography.Oid]"RSA").Value)

    # SHA256 Object
    $sha256 = New-Object -ComObject X509Enrollment.CObjectId
    $sha256.InitializeFromValue(([Security.Cryptography.Oid]"SHA256").Value)

    # Subject
    $subject = "CN=Sitecore, O=AWS Quick Start, OU=Created by https://aws.amazon.com/quickstart/"
    $subjectDN = New-Object -ComObject X509Enrollment.CX500DistinguishedName
    $subjectDN.Encode($Subject, 0x0)

    # Subject Alternative Names
    $san = New-Object -ComObject X509Enrollment.CX509ExtensionAlternativeNames
    $names = New-Object -ComObject X509Enrollment.CAlternativeNames
    foreach ($sanName in $DNSNames) {
        $name = New-Object -ComObject X509Enrollment.CAlternativeName
        $name.InitializeFromString(3, $sanName)
        $names.Add($name)
    }
    $san.InitializeEncode($names)

    # Private Key
    $privateKey = New-Object -ComObject X509Enrollment.CX509PrivateKey
    $privateKey.ProviderName = "Microsoft Enhanced RSA and AES Cryptographic Provider"
    $privateKey.Length = 2048
    $privateKey.ExportPolicy = 1 # Allow Export
    $privateKey.KeySpec = 1
    $privateKey.Algorithm = $rsa
    $privateKey.MachineContext = $location.MachineContext
    $privateKey.Create()

    # Certificate Object
    $certificate = New-Object -ComObject X509Enrollment.CX509CertificateRequestCertificate
    $certificate.InitializeFromPrivateKey($location.Value, $privateKey, "")
    $certificate.Subject = $subjectDN
    $certificate.NotBefore = ($date).AddDays(-1)

    if ($Signer) {
        # WebServer Certificate
        # WebServer Extensions
        $usage = New-Object -ComObject X509Enrollment.CObjectIds
        $keys = '1.3.6.1.5.5.7.3.2', '1.3.6.1.5.5.7.3.1' #Client Authentication, Server Authentication
        foreach ($key in $keys) {
            $keyObj = New-Object -ComObject X509Enrollment.CObjectId
            $keyObj.InitializeFromValue($key)
            $usage.Add($keyObj)
        }

        $webserverEnhancedKeyUsage = New-Object -ComObject X509Enrollment.CX509ExtensionEnhancedKeyUsage
        $webserverEnhancedKeyUsage.InitializeEncode($usage)

        $webserverBasicKeyUsage = New-Object -ComObject X509Enrollment.CX509ExtensionKeyUsage
        $webserverBasicKeyUsage.InitializeEncode([Security.Cryptography.X509Certificates.X509KeyUsageFlags]"DataEncipherment")
        $webserverBasicKeyUsage.Critical = $true

        # Signing CA cert needs to be in MY Store to be read as we need the private key.
        Move-Item -Path $Signer.PsPath -Destination $certificateLocation -Confirm:$false

        $signerCertificate = New-Object -ComObject X509Enrollment.CSignerCertificate
        $signerCertificate.Initialize($location.MachineContext, 0, 0xc, $Signer.Thumbprint)

        # Return the signing CA cert to the original location.
        Move-Item -Path "$certificateLocation\$($Signer.PsChildName)" -Destination $Signer.PSParentPath -Confirm:$false

        # Set issuer to root CA.
        $issuer = New-Object -ComObject X509Enrollment.CX500DistinguishedName
        $issuer.Encode($signer.Issuer, 0)

        $certificate.Issuer = $issuer
        $certificate.SignerCertificate = $signerCertificate
        $certificate.NotAfter = ($date).AddYears(5)
        $certificate.X509Extensions.Add($webserverEnhancedKeyUsage)
        $certificate.X509Extensions.Add($webserverBasicKeyUsage)

    }
    else {
        # Root CA
        # CA Extensions
        $rootEnhancedKeyUsage = New-Object -ComObject X509Enrollment.CX509ExtensionKeyUsage
        $rootEnhancedKeyUsage.InitializeEncode([Security.Cryptography.X509Certificates.X509KeyUsageFlags]"DigitalSignature,KeyEncipherment,KeyCertSign")
        $rootEnhancedKeyUsage.Critical = $true

        $basicConstraints = New-Object -ComObject X509Enrollment.CX509ExtensionBasicConstraints
        $basicConstraints.InitializeEncode($true, -1)
        $basicConstraints.Critical = $true

        $certificate.Issuer = $subjectDN #Same as subject for root CA
        $certificate.NotAfter = ($date).AddYears(10)
        $certificate.X509Extensions.Add($rootEnhancedKeyUsage)
        $certificate.X509Extensions.Add($basicConstraints)

    }

    $certificate.X509Extensions.Add($san) # Add SANs to Certificate
    $certificate.SignatureInformation.HashAlgorithm = $sha256
    $certificate.AlternateSignatureAlgorithm = $false
    $certificate.Encode()

    # Insert Certificate into Store
    $enroll = New-Object -ComObject X509Enrollment.CX509enrollment
    $enroll.CertificateFriendlyName = $FriendlyName
    $enroll.InitializeFromRequest($certificate)
    $certificateData = $enroll.CreateRequest(1)
    $enroll.InstallResponse(2, $certificateData, 1, "")

    # Retrieve thumbprint from $certificateData
    $certificateByteData = [System.Convert]::FromBase64String($certificateData)
    $createdCertificate = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Certificate2
    $createdCertificate.Import($certificateByteData)

    # Locate newly created certificate.
    $newCertificate = Get-ChildItem -Path $certificateLocation | Where-Object { $_.Thumbprint -Like $createdCertificate.Thumbprint }

    # Move CA to root store.
    if (!$Signer) {
        Move-Item -Path $newCertificate.PSPath -Destination $rootCertificateLocation
        $newCertificate = Get-ChildItem -Path $rootCertificateLocation | Where-Object { $_.Thumbprint -Like $createdCertificate.Thumbprint }
    }

    return $newCertificate
}

#Export Certificates
function ExportCert {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingConvertToSecureStringWithPlainText", "")]
    param (
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert,
        [Parameter(Mandatory)]
        [string]$Path,
        [string]$Name = 'certificate',
        [switch]$IncludePrivateKey,
        [securestring]$Password
    )
    $CertificatePath = $path + '\certificates'
    if (-not (Test-Path -LiteralPath $CertificatePath)) {
        New-Item -Path $CertificatePath -ItemType Directory
    }

    $params = @{
        Cert = $Cert
    }

    $return = @{ }

    if ($IncludePrivateKey) {
        if (!$Password) {
            $pass = Invoke-RandomStringConfigFunction -Length 20 -EnforceComplexity
            Write-Information -MessageData "Password used for encryption: $pass" -InformationAction "Continue"
            $params.Password = ConvertTo-SecureString -String $pass -AsPlainText -Force
        }
        else {
            $params.Password = $Password
        }

        $params.FilePath = "$CertificatePath\$Name.pfx"

        Export-PfxCertificate @params
        $return.certname = "$Name.pfx"

    }
    else {

        $params.FilePath = "$CertificatePath\$Name.crt"

        Export-Certificate @params
        $return.certname = "$Name.crt"
    }

    Write-Information -MessageData "Exported certificate file $($params.FilePath)" -InformationAction 'Continue'
    $return.localPath = $params.FilePath

    return $return
}

function ValidateCertificate {
    Param (
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert
    )

    Write-Verbose -Message "Checking certificate $($Cert.Thumbprint) for validity."

    if ((Test-Certificate -Cert $Cert -AllowUntrustedRoot -ErrorAction:SilentlyContinue) -eq $false) {
        Write-Verbose -Message "Certificate rejected by Test-Certificate."
        return $false
    }

    if ($Cert.HasPrivateKey -eq $false) {
        Write-Verbose -Message "Certificate has no private key."
        return $false
    }

    Write-Verbose -Message "Certificate is OK."
    return $true

}

function CopyToS3Bucket {
    param (
        [String]$BucketName,
        [String]$BucketPrefix,
        [String]$ObjectName,
        [String]$LocalFileName
    )

    $key = $bucketPrefix + $objectName
    $bucket_locationConstraint = Get-S3BucketLocation -BucketName $BucketName
    $BucketRegionValue = $bucket_locationConstraint.value

    if (!$BucketRegionValue) { # Get-S3BucketLocation returns Null when the bucket is located in us-east-1
            $bucketRegion = 'us-east-1'
        }
    elseif ($BucketRegionValue -eq 'EU') {
            $bucketRegion = 'eu-west-1'
        }
    else {
            $bucketRegion =  $BucketRegionValue
        }
    
    Write-S3Object -BucketName $bucketName -File $localFileName -Key $key -Region $bucketRegion -Verbose

    Return "$bucketName\$key"
}

function WriteToParameterStore {
    Param (
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert,
        [String] $type
    )
    Write-SSMParameter -Name "/$SCQSPrefix/cert/$type/thumbprint" -Type "String" -Value $cert.Thumbprint
}

# Creates the RootCA, moves it to Cert:\LocalMachine\Root and validates that it is correct (Returns True)
Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $logStreamName -LogString 'Creating the Sitecore Root cert...'
$root = NewCertificate `
    -FriendlyName $RootFriendlyName `
    -DNSNames $RootDNSNames `
    -CertStoreLocation $CertStoreLocation `

Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $logStreamName -LogString $root

$ValidateRootCA = ValidateCertificate -Cert $root
Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $logStreamName -LogString 'Exporting Root certificate...'
$ExportRootCA = ExportCert -Cert $root -Path $ExportPath -Name $ExportRootCertName -IncludePrivateKey -Password $ExportPassword
Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $logStreamName -LogString "Exported Root certificate $ExportRootCA"

Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $logStreamName -LogString 'Copying Root certificate to S3...'
$RootCAToS3 = CopyToS3Bucket -bucketName $S3BucketName -bucketPrefix $S3BucketCertificatePrefix -objectName $ExportRootCA.certname -localFileName $ExportRootCA.localPath
Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $logStreamName -LogString $RootCAToS3

# Creates the Sitecore Instance cert based on the RootCA and validates that it is correct (Returns True)
Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $logStreamName -LogString 'Creating the Sitecore Instance cert based on the generated RootCA...'
$signedCertificate = NewCertificate `
    -FriendlyName $InstanceFriendlyName `
    -DNSNames $InstanceDNSNames `
    -Signer $root
Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $logStreamName -LogString $signedCertificate

# Create Parameter entry for instance certificate thumbprint
Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $logStreamName -LogString 'Writing Certificate thumbprint to Parameter Store'
WriteToParameterStore -Cert $signedCertificate -type 'instance'

$ValidateInstanceCert = ValidateCertificate -Cert $signedCertificate
Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $logStreamName -LogString 'Exporting Instance certificate...'
$exportinstanceCert = ExportCert -Cert $signedCertificate -Path $ExportPath -Name $ExportInstanceCertName -IncludePrivateKey -Password $ExportPassword
Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $logStreamName -LogString "Exported Instance certificate $exportinstanceCert"

Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $logStreamName -LogString 'Copying Instance certificate to S3...'
$InstanceCertToS3 = CopyToS3Bucket -bucketName $S3BucketName -bucketPrefix $S3BucketCertificatePrefix -objectName $exportinstanceCert.certname -localFileName $exportinstanceCert.localPath
Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $logStreamName -LogString $InstanceCertToS3

# Creates the Sitecore XConnect cert based on the RootCA and validates that it is correct (Returns True)
Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $logStreamName -LogString 'Creating the Sitecore Collection Search cert based on the generated RootCA...'
$signedCertificate = NewCertificate `
    -FriendlyName $XConnectFriendlyName `
    -DNSNames $xConnectDNSNames `
    -Signer $root
Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $logStreamName -LogString $signedCertificate

# Create Parameter entry for xconnect certificate thumbprint
Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $logStreamName -LogString 'Writing Certificate thumbprint to Parameter Store'
WriteToParameterStore -Cert $signedCertificate -type 'xconnect'

Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $logStreamName -LogString 'Exporting Collection Search certificate...'
$exportxconnectCert = ExportCert -Cert $signedCertificate -Path $ExportPath -Name $ExportXConnectCertName -IncludePrivateKey -Password $ExportPassword
Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $logStreamName -LogString "Exported Collection Search certificate $exportxconnectCert"

Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $logStreamName -LogString 'Copying Collection Search  certificate to S3...'
$XconnectCertToS3 = CopyToS3Bucket -bucketName $S3BucketName -bucketPrefix $S3BucketCertificatePrefix -objectName $exportxconnectCert.certname -localFileName $exportxconnectCert.localPath
Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $logStreamName -LogString $XconnectCertToS3