#  Copyright 2016 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
#  This file is licensed to you under the AWS Customer Agreement (the "License").
#  You may not use this file except in compliance with the License.
#  A copy of the License is located at http://aws.amazon.com/agreement/ .
#  This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied.
#  See the License for the specific language governing permissions and limitations under the License.

[CmdletBinding()]
param (
    [string]$SCQSPrefix,
    [string]$Role
)

$SCInstallRoot = (Get-SSMParameter -Name "/$SCQSPrefix/user/localresourcespath").Value # Local location where resource files are kept
$s3BucketName = (Get-SSMParameter -Name "/$SCQSPrefix/user/s3bucket/name").Value # The Sitecore resources bucket
$LicencePrefix = (Get-SSMParameter -Name "/$SCQSPrefix/user/s3bucket/sclicenseprefix").Value # The prefix in the bucket where the Sitecore License is kept
$CertificatePrefix = (Get-SSMParameter -Name "/$SCQSPrefix/user/s3bucket/certificateprefix").Value # The prefix in the bucket where the certificate is kept (both Sitecore and SolrDev)
$xConnectCertificateName = (Get-SSMParameter -Name "/$SCQSPrefix/cert/xconnect/exportname").Value # The Sitecore Collection Search exported Client Authentication certificate name
$CertificateName = (Get-SSMParameter -Name "/$SCQSPrefix/cert/instance/exportname").Value # The Sitecore instance exported Instance certificate name
$RootCertificateName = (Get-SSMParameter -Name "/$SCQSPrefix/cert/root/exportname").Value# The Sitecore instance exported Root certificate name
$CertPassword = (ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId "sitecore-quickstart-$SCQSPrefix-certpass").SecretString).password
$CertSecurePassword = ConvertTo-SecureString $CertPassword -AsPlainText -Force

$logGroupName = $SCQSPrefix + "-" + $Role
$logStreamLicense = "LicenseFile-" + (Get-Date (Get-Date).ToUniversalTime() -Format "MM-dd-yyyy" )
$logStreamCert = "CertImport-" + (Get-Date (Get-Date).ToUniversalTime() -Format "MM-dd-yyyy" )

function cert_import {
    [CmdletBinding()]
    param (
        [string] $CertBucketName,
        [string] $CertPrefix,
        [string] $CertName,
        [securestring] $CertPass,
        [string] $CertStoreLocation
    )
    
    begin {
        $bucket_locationConstraint = Get-S3BucketLocation -BucketName $CertBucketName
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
        $CertPath = $CertPrefix + $CertName + '.pfx'
        $CertLocation = 'c:\certificates'
        $LocalCertFile = "$CertLocation\$CertName.pfx"
    }
    
    process {
        if (-not (Test-Path -LiteralPath $CertLocation)) {
            Write-AWSQuickStartCWLogsEntry -LogGroupName $logGroupName -LogStreamName $logStreamCert -LogString (New-Item -Path $CertLocation -ItemType Directory -Verbose)
        }
        else {
            Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $logStreamCert -LogString "$CertLocation already exists"
        }
        
        Read-S3Object -BucketName $CertBucketName -Region $bucketRegion -Key $CertPath -File $LocalCertFile
        $CertImport = Import-PfxCertificate -FilePath $LocalCertFile -CertStoreLocation $CertStoreLocation -Password $CertPass -Exportable
        Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $logStreamCert -LogString $CertImport
    }
    
    end {
        
    }
}


function licence_download {
    [CmdletBinding()]
    param (
        [string] $LicenseBucketName,
        [string] $LicenseObjPrefix,
        [string] $LicenseInstance
    )
    
    begin {
        $bucket_locationConstraint = Get-S3BucketLocation -BucketName $LicenseBucketName
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
    }
    
    process {
        $file = Get-S3Object -BucketName $LicenseBucketName -Region $bucketRegion | Where-Object { ($_.Key -like "$LicenseObjPrefix*license.zip") -or ($_.Key -like "$LicencePrefix*license.xml") }

        if (($file.key -like '*license.zip')) {
            Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $logStreamLicense -LogString (Read-S3Object -BucketName $LicenseBucketName -Region $bucketRegion -Key $file.key -File "$LicenseInstance\license.zip" | Out-String)
            Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $logStreamLicense -LogString (Expand-Archive -LiteralPath "$LicenseInstance\license.zip" -DestinationPath $LicenseInstance -Force -Verbose *>&1 | Out-String)
        }
        
        elseif (($file.key -like '*license.xml')) {
            Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $logStreamLicense -LogString (Read-S3Object -BucketName $LicenseBucketName -Region $bucketRegion -Key $file.key -File "$LicenseInstance\license.xml")
        }
        
    }
    
    end {
        
    }
}

# Import Root Cert
cert_import -CertBucketName $s3BucketName -CertPrefix $CertificatePrefix -CertName $RootCertificateName -CertStoreLocation 'Cert:\LocalMachine\Root' -CertPass $CertSecurePassword
# Import Instance Cert
cert_import -CertBucketName $s3BucketName -CertPrefix $CertificatePrefix -CertName $CertificateName -CertStoreLocation 'Cert:\LocalMachine\My' -CertPass $CertSecurePassword
# Import Collection Search Cert
cert_import -CertBucketName $s3BucketName -CertPrefix $CertificatePrefix -CertName $xConnectCertificateName -CertStoreLocation 'Cert:\LocalMachine\My' -CertPass $CertSecurePassword
# Download Sitecore License
licence_download -LicenseBucketName $s3BucketName -LicenseObjPrefix $LicencePrefix -LicenseInstance $SCInstallRoot

Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $logStreamCert -LogString "Preperation completed for installation of role : $Role"