[CmdletBinding()]
param (
    [string]$SCQSPrefix
)

$SCPrefix = (Get-SSMParameter -Name "/$SCQSPrefix/user/sitecoreprefix").Value
$filepath = "C:\inetpub\wwwroot\$SCPrefix.CD\App_Config\ConnectionStrings.config"

# CloudWatch values
logGroupName  = "$SCQSPrefix-CD"
LogStreamName = "update-cs-config-" + (Get-Date (Get-Date).ToUniversalTime() -Format "MM-dd-yyyy" )

Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $LogStreamName -LogString "Updating ConnectionStrings.config file for Solr Search"

$connectionString = (Get-SSMParameter -Name "/$SCQSPrefix/user/solruri").Value
#$cwScript = (Get-SSMParameter -Name "/$SCQSPrefix/user/localqsresourcespath").Value

#$filepath = '/c/dev/resourcefiles/configfiles/ConnectionStrings.config'
$xml = New-Object -TypeName xml
$xml.Load($filepath)
$item = Select-Xml -Xml $xml -XPath '//add[@name="solr.search"]'
$newnode = $item.Node.CloneNode($true)

$newnode.name = 'session'
$newnode.connectionString = $connectionString
$cs = Select-Xml -Xml $xml -XPath '//connectionStrings'
$out = ($cs.Node.AppendChild($newnode)*>&1 | Out-String)

Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $LogStreamName -LogString $out

$xml.Save($filepath)