[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string]$hostedZoneID,
    [string]$SCQSPrefix
)

# $urlsuffix = (Get-SSMParameter -Name "/$SCQSPrefix/service/internaldns").Value 
$SolrDNS = (Get-SSMParameter -Name "/$SCQSPrefix/service/solrdevfqdn").Value  # 'solrdev.' + $urlsuffix 
$SolrURL = (Get-SSMParameter -Name "/${SCQSPrefix}/user/solruri").Value
$SolrVersion = "8.1.1"
$SolrPort = 8983
$SolrCorePrefix = (Get-SSMParameter -Name "/$SCQSPrefix/user/solrcoreprefix").Value # Path on the instance where the files will be located
$localPath = (Get-SSMParameter -Name "/$SCQSPrefix/user/localresourcespath").Value # Path on the instance where the files will be located
$localLogPath = "$localPath\logs" # Path on the instance where the log files will be located
# $qslocalPath = (Get-SSMParameter -Name "/$SCQSPrefix/user/localqsresourcespath").Value # Path on the instance where the Quick Start files will be located
$localCertpath = "$localPath\certificates" # Path on the instance where the log files will be located
$RawPassword = (ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId "sitecore-quickstart-$SCQSPrefix-certpass").SecretString).password
$ExportPassword = ConvertTo-SecureString $RawPassword -AsPlainText -Force
# $S3BucketName = (Get-SSMParameter -Name "/$SCQSPrefix/user/s3bucket/name").Value
# $S3BucketCertificatePrefix = (Get-SSMParameter -Name "/$SCQSPrefix/user/s3bucket/certificateprefix").Value

# Check and create logs path
If(!(test-path $localLogPath))
{
      New-Item -ItemType Directory -Force -Path $localLogPath
}
If(!(test-path $localCertpath))
{
      New-Item -ItemType Directory -Force -Path $localCertpath
}

# CloudWatch values
$logGroupName = "$SCQSPrefix-solr-dev-install"
$logStreamName = "Solr-Install-" + (Get-Date (Get-Date).ToUniversalTime() -Format "MM-dd-yyyy" )

Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $LogStreamName -LogString 'Starting deployment of Solr Dev server'

# Installing Solr
$SolrParameters = @{
    SolrVersion               = $SolrVersion
    SolrDomain                = $SolrDNS
    SolrPort                  = $SolrPort
    # SolrServicePrefix         = ""
    # SolrInstallRoot           = "C:\\"
    # SolrSourceURL             = "http://archive.apache.org/dist/lucene/solr"
    # JavaDownloadURL           = "https://github.com/AdoptOpenJDK/openjdk8-binaries/releases/download/jdk8u222-b10/OpenJDK8U-jre_x64_windows_hotspot_8u222b10.zip"
    # ApacheCommonsDaemonURL    = "http://archive.apache.org/dist/commons/daemon/binaries/windows/commons-daemon-1.1.0-bin-windows.zip"
    # TempLocation              = "SIF-Default"
    # ServiceLocation           = "HKLM:SYSTEM\\CurrentControlSet\\Services"
}

Install-SitecoreConfiguration @SolrParameters -Path "$localPath\Solr-SingleDeveloper.json" -Verbose *>&1 | Tee-Object "$localLogPath\solr-install.log"
Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $LogStreamName -LogString $(Get-Content -Path "$localLogPath\solr-install.log" -raw)

# Pause time for the Target Group to catch up on seeing the instance as healthy
Start-Sleep -Seconds 180

# If private DNS is used, set the host file to point locally to initiate the Solr Cores. (This entry is removed later)
If ($R53HostedZoneID -eq '') {
    $hostfile = "$($env:windir)\system32\Drivers\etc\hosts"
    $hostentry = "127.0.0.1 $SolrDNS"

    If ((Get-Content $hostfile ) -notcontains $hostentry) {
        Add-Content -Encoding UTF8  $hostfile $hostentry 
        Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $LogStreamName -LogString 'Adding Host file entry to deploy Solr Cores'
        }
}

Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $LogStreamName -LogString 'Starting creation of Sitecore Cores on SolrDev server'

# Configuring Solr Cores
$sitecoreSolrCores = @{
    SolrUrl = "$SolrURL"
    SolrRoot = "c:\\solr-$SolrVersion"
    SolrService = "Solr-$SolrVersion"
    # BaseConfig = ""
    CorePrefix = "$SolrCorePrefix"
}

Install-SitecoreConfiguration @sitecoreSolrCores -Path "$localPath\sitecore-solr.json" -Verbose *>&1 | Tee-Object "$localLogPath\solr-cores-install.log"
Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $LogStreamName -LogString $(Get-Content -Path "$localLogPath\solr-cores-install.log" -raw)

Install-SitecoreConfiguration @sitecoreSolrCores -Path "$localPath\xconnect-solr.json" -Verbose *>&1 | Tee-Object "$localLogPath\xconnect-cores-install.log"
Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $LogStreamName -LogString $(Get-Content -Path "$localLogPath\xconnect-cores-install.log" -raw)

Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $LogStreamName -LogString 'Solr Cores creation complete'

# If private DNS is used, remove the created host file entry
If ($R53HostedZoneID -eq '') {
    $hostfile = "$($env:windir)\system32\Drivers\etc\hosts"
    $hostentry = "127.0.0.1 $SolrDNS"

    If ((Get-Content $hostfile ) -contains $hostentry) {
        (Get-Content -Path $hostfile) |
        ForEach-Object {$_ -Replace $hostentry, ''} |
            Set-Content -Path $hostfile
        Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $LogStreamName -LogString 'Removing Host file entry'
    }
}
