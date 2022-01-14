[CmdletBinding()]
param (
    [string]$SCQSPrefix
)


$SCPrefix = (Get-SSMParameter -Name "/$SCQSPrefix/user/sitecoreprefix").Value
$webfilepath = "C:\inetpub\wwwroot\$SCPrefix.CD\Web.config"
$constringfilepath = "C:\inetpub\wwwroot\$SCPrefix.CD\App_Config\ConnectionStrings.config"
$connectionString = (Get-SSMParameter -Name "/$SCQSPrefix/redis/url").Value

# CloudWatch values
$logGroupName  = "$SCQSPrefix-CD"
$LogStreamName = "Update-Redis-Configuration" + (Get-Date (Get-Date).ToUniversalTime() -Format "MM-dd-yyyy" )


function redisPrivateWebConfig {

    Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $LogStreamName -LogString "Updating web.config file for Redis Private session state"
    #$filepath = '/c/dev/resourcefiles/configfiles/Web.config'
    $xml = New-Object -TypeName xml
    $xml.Load($webfilepath)
    $item = Select-Xml -Xml $xml -XPath '//sessionState'

    #Remove the node
    $null = $item.Node.ParentNode.RemoveChild($item.Node)

    #Create the replacement node
    $sessionState = $xml.CreateElement("sessionState")
    $sessionState.SetAttribute("mode", "Custom")
    $sessionState.SetAttribute("customProvider", "redis")
    $sessionState.SetAttribute("timeout", "20")

    $providers = $xml.CreateElement("providers")

    $add = $xml.CreateElement("add")
    $add.SetAttribute("name", "redis")
    $add.SetAttribute("type", "Sitecore.SessionProvider.Redis.RedisSessionStateProvider, Sitecore.SessionProvider.Redis")
    $add.SetAttribute("connectionString", "session")
    $add.SetAttribute("pollingInterval", "2")
    $add.SetAttribute("applicationName", "private")

    $providers.AppendChild($add)
    $sessionState.AppendChild($providers)
    $xml.configuration.'system.web'.AppendChild($sessionState)
    $xml.Save($webfilepath)
    $sessionState.AppendChild($providers)
    $out = ($xml.configuration.'system.web'.AppendChild($sessionState)*>&1 | Out-String) 

    Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $LogStreamName -LogString $out

    $xml.Save($webfilepath)
}

function redisSharedWebConfig {    
    begin {
        Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $LogStreamName -LogString "Updating Sitecore.Analytics.Tracking.config file for Redis Shared session state"
        $RedisSharedConfigPath = 'C:\inetpub\wwwroot\sc.CD\App_Config\Sitecore\Marketing.Tracking\Sitecore.Analytics.Tracking.config'
    }
    
    process {
        $searchString = '<add name="InProc" type="System.Web.SessionState.InProcSessionStateStore" />'
        $replaceString = '<add name="redis" type="Sitecore.SessionProvider.Redis.RedisSessionStateProvider,  
                                    Sitecore.SessionProvider.Redis"
                                    connectionString="sharedSession"
                                    pollingInterval="2"
                                    applicationName="shared"/>'
        

        $contents = Get-Content -Path $RedisSharedConfigPath -Raw
        $newContent = $contents -replace $searchString, $replaceString

        $newContent | Set-Content -Path $RedisSharedConfigPath
    }
    
    end {
        Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $LogStreamName -LogString $replaceString
    }
}

function ConnectionStringAdd {
    [CmdletBinding()]
    param (
        $xmlPath,
        $nodename,
        $newconnectionString
    )
    
    begin {
        Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $LogStreamName -LogString "Updating App_Config\ConnectionStrings.config file for Redis $nodename state"
    }
    
    process {
        $xml = New-Object -TypeName xml
        $xml.Load($xmlPath)
        $item = Select-Xml -Xml $xml -XPath '//add[@name="xconnect.collection"]'
        $newnode = $item.Node.CloneNode($true)

        $newnode.name = $nodename
        $newnode.connectionString = $newconnectionString
        $cs = Select-Xml -Xml $xml -XPath '//connectionStrings'
        $out = ($cs.Node.AppendChild($newnode)*>&1 | Out-String)

        $xml.Save($xmlPath)
    }
    
    end {
        Write-AWSQuickStartCWLogsEntry -logGroupName $logGroupName -LogStreamName $LogStreamName -LogString $out
    }
}

ConnectionStringAdd -xmlPath $constringfilepath -nodename 'session' -newconnectionString $connectionString
ConnectionStringAdd -xmlPath $constringfilepath -nodename 'sharedSession' -newconnectionString $connectionString

redisPrivateWebConfig
redisSharedWebConfig
