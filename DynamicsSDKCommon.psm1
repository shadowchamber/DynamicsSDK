<# Common PowerShell functions used by the Dynamics AX 7.0 build process. #>

<#
.SYNOPSIS
    Import this module to get a Write-Message function for controlling output.
    
.DESCRIPTION
    This script can be imported to log messages of type message, error or warning. 
    If no $LogPath variable is defined it will write to host using either Write-Host,
    Write-Warning, Write-Error, or Write-Verbose.

.NOTES
    When running through automation, set the $LogPath variable to redirect
    all output to a log file rather than the console. Can be set in calling script.

    Copyright © 2016 Microsoft. All rights reserved.
#>
function Write-Message
{
    [Cmdletbinding()]
    Param([string]$Message, [switch]$Error, [switch]$Warning, [switch]$Diag, [string]$LogPath = $PSCmdlet.GetVariableValue("LogPath"))

    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")

    if ($LogPath)
    {
        # For log files use full UTC time stamp.
        "$([DateTime]::UtcNow.ToString("s")): $($Message)" | Out-File -FilePath $LogPath -Append
    }
    else
    {
        # For writing to host use a local time stamp.
        [string]$FormattedMessage = "$([DateTime]::Now.ToLongTimeString()): $($Message)"
        
        # If message is of type Error, use Write-Error.
        if ($Error)
        {
            Write-Error $FormattedMessage
        }
        else
        {
            # If message is of type Warning, use Write-Warning.
            if ($Warning)
            {
                Write-Warning $FormattedMessage
            }
            else
            {
                # If message is of type Verbose, use Write-Verbose.
                if ($Diag)
                {
                    Write-Verbose $FormattedMessage
                }
                else
                {
                    Write-Host $FormattedMessage
                }
            }
        }
    }
}

<#
.SYNOPSIS
    Set DynamicsSDK machine wide environment variables. These are used by the
    build process.
#>
function Set-AX7SdkEnvironmentVariables
{
    [Cmdletbinding()]
    Param([string]$DynamicsSDK)

    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")

    # If specified, save DynamicsSDK in registry and machine wide environment variable.
    if ($DynamicsSDK)
    {
        Write-Message "- Setting machine wide DynamicsSDK environment variable: $DynamicsSDK" -Diag
        [Environment]::SetEnvironmentVariable("DynamicsSDK", $DynamicsSDK, "Machine")
    }
    else
    {
        Write-Message "- No DynamicsSDK value specified. No environment variable will be set." -Diag
    }
}

<#
.SYNOPSIS
    Set DynamicsSDK, TeamFoundationServerUrl, AosWebsiteName and BackupPath registry values.
    These are used by the build process.
#>
function Set-AX7SdkRegistryValues
{
    [Cmdletbinding()]
    Param([string]$DynamicsSDK, [string]$TeamFoundationServerUrl, [string]$AosWebsiteName, [string]$BackupPath)

    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")

    $RegPath = "HKLM:\SOFTWARE\Microsoft\Dynamics\AX\7.0\SDK"

    if (!(Test-Path -Path $RegPath))
    {
        Write-Message "- Creating new Dynamics SDK registry key: $RegPath" -Diag
        $RegKey = New-Item -Path $RegPath -Force
    }

    # If specified, save DynamicsSDK in registry.
    if ($DynamicsSDK)
    {
        Write-Message "- Setting DynamicsSDK registry value: $DynamicsSDK" -Diag
        $RegValue = New-ItemProperty -Path $RegPath -Name "DynamicsSDK" -Value $DynamicsSDK -Force
    }
    else
    {
        Write-Message "- No DynamicsSDK value specified. No registry value will be set" -Diag
    }
    
    # If specified, save TeamFoundationServerUrl in registry.
    if ($TeamFoundationServerUrl)
    {
        Write-Message "- Setting TeamFoundationServerUrl registry value: $TeamFoundationServerUrl" -Diag
        $RegValue = New-ItemProperty -Path $RegPath -Name "TeamFoundationServerUrl" -Value $TeamFoundationServerUrl -Force
    }
    else
    {
        Write-Message "- No TeamFoundationServerUrl value specified. No registry value will be set." -Diag
    }

    # If specified, save AosWebsiteName in registry.
    if ($AosWebsiteName)
    {
        Write-Message "- Setting AosWebsiteName registry value: $AosWebsiteName" -Diag
        $RegValue = New-ItemProperty -Path $RegPath -Name "AosWebsiteName" -Value $AosWebsiteName -Force
    }
    else
    {
        Write-Message "- No AosWebsiteName value specified. No registry value will be set." -Diag
    }

    # If specified, save BackupPath in registry.
    if ($BackupPath)
    {
        Write-Message "- Setting BackupPath registry value: $BackupPath" -Diag
        $RegValue = New-ItemProperty -Path $RegPath -Name "BackupPath" -Value $BackupPath -Force
    }
    else
    {
        Write-Message "- No BackupPath value specified. No registry value will be set." -Diag
    }
}

<#
.SYNOPSIS
    Set values in the Dynamics SDK registry key from the AOS web config.
    These are used by the build process and read in properties of project and
    target files.
#>
function Set-AX7SdkRegistryValuesFromAosWebConfig
{
    [Cmdletbinding()]
    Param([string]$AosWebsiteName)
    
    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")

    $RegPath = "HKLM:\SOFTWARE\Microsoft\Dynamics\AX\7.0\SDK"

    if (!(Test-Path -Path $RegPath))
    {
        Write-Message "- Creating new Dynamics SDK registry key: $RegPath" -Diag
        $RegKey = New-Item -Path $RegPath -Force
    }
    
    # If specified, save AosWebsiteName in registry.
    if ($AosWebsiteName)
    {
        Write-Message "- Setting AosWebsiteName registry value: $AosWebsiteName" -Diag
        $RegValue = New-ItemProperty -Path $RegPath -Name "AosWebsiteName" -Value $AosWebsiteName -Force
    }
    else
    {
        $RegKey = Get-ItemProperty -Path $RegPath
        $AosWebsiteName = $RegKey.AosWebsiteName
        if ($AosWebsiteName)
        {
            Write-Message "- No AOS website name specified. Using existing value from registry: $AosWebsiteName" -Diag
        }
        else
        {
            throw "No AOS website name specified and no existing value found in registry at: $RegPath"
        }
    }

    # Get AOS web.config and extract values to save in Dynamics SDK registry. These will be read
    # by the MSBuild projects.
    $WebConfigPath = Get-AX7DeploymentAosWebConfigPath -WebsiteName $AosWebsiteName
    
    if ($WebConfigPath -and (Test-Path -Path $WebConfigPath -PathType Leaf))
    {
        $BinariesPath = Get-AX7DeploymentBinariesPath -WebConfigPath $WebConfigPath
        if ($BinariesPath)
        {
            Write-Message "- Setting BinariesPath registry value: $BinariesPath" -Diag
            $RegValue = New-ItemProperty -Path $RegPath -Name "BinariesPath" -Value $BinariesPath -Force
        }
        else
        {
            Write-Message "- No BinariesPath could be found in AOS web.config: $WebConfigPath" -Warning
        }
    
        $MetadataPath = Get-AX7DeploymentMetadataPath -WebConfigPath $WebConfigPath
        if ($MetadataPath)
        {
            Write-Message "- Setting MetadataPath registry value: $MetadataPath" -Diag
            $RegValue = New-ItemProperty -Path $RegPath -Name "MetadataPath" -Value $MetadataPath -Force
        }
        else
        {
            Write-Message "- No MetadataPath could be found in AOS web.config: $WebConfigPath" -Warning
        }
    
        $PackagesPath = Get-AX7DeploymentPackagesPath -WebConfigPath $WebConfigPath
        if ($PackagesPath)
        {
            Write-Message "- Setting PackagesPath registry value: $PackagesPath" -Diag
            $RegValue = New-ItemProperty -Path $RegPath -Name "PackagesPath" -Value $PackagesPath -Force
        }
        else
        {
            Write-Message "- No PackagesPath could be found in AOS web.config: $WebConfigPath" -Warning
        }

        $DatabaseName = Get-AX7DeploymentDatabaseName -WebConfigPath $WebConfigPath
        if ($DatabaseName)
        {
            Write-Message "- Setting DatabaseName registry value: $DatabaseName" -Diag
            $RegValue = New-ItemProperty -Path $RegPath -Name "DatabaseName" -Value $DatabaseName -Force
        }
        else
        {
            Write-Message "- No DatabaseName could be found in AOS web.config: $WebConfigPath" -Warning
        }

        $DatabaseServer = Get-AX7DeploymentDatabaseServer -WebConfigPath $WebConfigPath
        if ($DatabaseServer)
        {
            Write-Message "- Setting DatabaseServer registry value: $DatabaseServer" -Diag
            $RegValue = New-ItemProperty -Path $RegPath -Name "DatabaseServer" -Value $DatabaseServer -Force
        }
        else
        {
            Write-Message "- No DatabaseServer could be found in AOS web.config: $WebConfigPath" -Warning
        }
    }
    else
    {
        throw "No AOS web config could be found for AOS website name: $AosWebsiteName"
    }
}

<#
.SYNOPSIS
    Get the Dynamics SDK path from the Dynamics SDK registry key.

.NOTES
    Throws exception if the Dynamics SDK registry path is not found.

.OUTPUTS
    System.String. The full path to the Dynamics SDK files.
#>
function Get-AX7SdkPath
{
    [Cmdletbinding()]
    Param()

    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")

    [string]$DynamicsSdk = $null

    $RegPath = "HKLM:\SOFTWARE\Microsoft\Dynamics\AX\7.0\SDK"
    
    # Get the Dynamics SDK registry key (throws if not found).
    Write-Message "- Getting Dynamics SDK registry key..." -Diag
    $RegKey = Get-ItemProperty -Path $RegPath

    if ($RegKey -ne $null)
    {
        $DynamicsSdk = $RegKey.DynamicsSDK
        if ($DynamicsSdk)
        {
            Write-Message "- Found Dynamics SDK path: $DynamicsSdk" -Diag
        }
        else
        {
            Write-Message "- No Dynamics SDK path found in registry." -Diag
        }
    }

    return $DynamicsSdk
}

<#
.SYNOPSIS
    Get the Dynamics SDK backup path from the Dynamics SDK registry key.

.NOTES
    Throws exception if the Dynamics SDK registry path is not found.

.OUTPUTS
    System.String. The full path to the backup path.
#>
function Get-AX7SdkBackupPath
{
    [Cmdletbinding()]
    Param()

    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")

    [string]$BackupPath = $null

    $RegPath = "HKLM:\SOFTWARE\Microsoft\Dynamics\AX\7.0\SDK"
    
    # Get the Dynamics SDK registry key (throws if not found).
    Write-Message "- Getting Dynamics SDK registry key..." -Diag
    $RegKey = Get-ItemProperty -Path $RegPath

    if ($RegKey -ne $null)
    {
        $BackupPath = $RegKey.BackupPath
        if ($BackupPath)
        {
            Write-Message "- Found backup path: $BackupPath" -Diag
        }
        else
        {
            Write-Message "- No backup path found in registry." -Diag
        }
    }

    return $BackupPath
}

<#
.SYNOPSIS
    Get the VSO/Team Foundation Server URL from the Dynamics SDK registry key.

.NOTES
    Throws exception if the Dynamics SDK registry path is not found.

.OUTPUTS
    System.String. The VSO/Team Foundation Server URL.
#>
function Get-AX7SdkTeamFoundationServerUrl
{
    [Cmdletbinding()]
    Param()

    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")

    [string]$TeamFoundationServerUrl = $null

    $RegPath = "HKLM:\SOFTWARE\Microsoft\Dynamics\AX\7.0\SDK"
    
    # Get the Dynamics SDK registry key (throws if not found).
    Write-Message "- Getting Dynamics SDK registry key..." -Diag
    $RegKey = Get-ItemProperty -Path $RegPath

    if ($RegKey -ne $null)
    {
        $TeamFoundationServerUrl = $RegKey.TeamFoundationServerUrl
        if ($TeamFoundationServerUrl)
        {
            Write-Message "- Found Team Foundation Server URL: $TeamFoundationServerUrl" -Diag
        }
        else
        {
            Write-Message "- No Team Foundation Server URL found in registry." -Diag
        }
    }

    return $TeamFoundationServerUrl
}

<#
.SYNOPSIS
    Get the Dynamics AX deployment database name from the Dynamics SDK registry key.

.NOTES
    Throws exception if the Dynamics SDK registry path is not found.

.OUTPUTS
    System.String. The database name.
#>
function Get-AX7SdkDeploymentDatabaseName
{
    [Cmdletbinding()]
    Param()

    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")

    [string]$DatabaseName = $null

    $RegPath = "HKLM:\SOFTWARE\Microsoft\Dynamics\AX\7.0\SDK"
    
    # Get the Dynamics SDK registry key (throws if not found).
    Write-Message "- Getting Dynamics SDK registry key..." -Diag
    $RegKey = Get-ItemProperty -Path $RegPath

    if ($RegKey -ne $null)
    {
        $DatabaseName = $RegKey.DatabaseName
        if ($DatabaseName)
        {
            Write-Message "- Found database name: $DatabaseName" -Diag
        }
        else
        {
            Write-Message "- No database name found in registry." -Diag
        }
    }

    return $DatabaseName
}

<#
.SYNOPSIS
    Get the Dynamics AX deployment database server from the Dynamics SDK registry key.

.NOTES
    Throws exception if the Dynamics SDK registry path is not found.

.OUTPUTS
    System.String. The database server name.
#>
function Get-AX7SdkDeploymentDatabaseServer
{
    [Cmdletbinding()]
    Param()

    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")

    [string]$DatabaseServer = $null

    $RegPath = "HKLM:\SOFTWARE\Microsoft\Dynamics\AX\7.0\SDK"
    
    # Get the Dynamics SDK registry key (throws if not found).
    Write-Message "- Getting Dynamics SDK registry key..." -Diag
    $RegKey = Get-ItemProperty -Path $RegPath

    if ($RegKey -ne $null)
    {
        $DatabaseServer = $RegKey.DatabaseServer
        if ($DatabaseServer)
        {
            Write-Message "- Found database server: $DatabaseServer" -Diag
        }
        else
        {
            Write-Message "- No database server found in registry." -Diag
        }
    }

    return $DatabaseServer
}

<#
.SYNOPSIS
    Get the Dynamics AX deployment AOS website name from the Dynamics SDK registry key.

.NOTES
    Throws exception if the Dynamics SDK registry path is not found.

.OUTPUTS
    System.String. The deployment AOS website name.
#>
function Get-AX7SdkDeploymentAosWebsiteName
{
    [Cmdletbinding()]
    Param()
    
    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")

    [string]$AosWebsiteName = $null

    $RegPath = "HKLM:\SOFTWARE\Microsoft\Dynamics\AX\7.0\SDK"
    
    # Get the Dynamics SDK registry key (throws if not found).
    Write-Message "- Getting Dynamics SDK registry key..." -Diag
    $RegKey = Get-ItemProperty -Path $RegPath

    if ($RegKey -ne $null)
    {
        Write-Message "- Getting deployment AOS website name..." -Diag
        $AosWebsiteName = $RegKey.AosWebsiteName
        if ($AosWebsiteName)
        {
            Write-Message "- Found deployment AOS website name: $AosWebsiteName" -Diag
        }
        else
        {
            Write-Message "- No deployment AOS website name found in registry." -Diag
        }
    }

    return $AosWebsiteName
}

<#
.SYNOPSIS
    Get the Dynamics AX deployment binaries path from Dynamics SDK registry key.

.NOTES
    Throws exception if the Dynamics SDK registry path is not found.

.OUTPUTS
    System.String. The full path to the deployment binaries.
#>
function Get-AX7SdkDeploymentBinariesPath
{
    [Cmdletbinding()]
    Param()

    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")

    [string]$BinariesPath = $null

    $RegPath = "HKLM:\SOFTWARE\Microsoft\Dynamics\AX\7.0\SDK"
    
    # Get the Dynamics SDK registry key (throws if not found).
    Write-Message "- Getting Dynamics SDK registry key..." -Diag
    $RegKey = Get-ItemProperty -Path $RegPath

    if ($RegKey -ne $null)
    {
        Write-Message "- Getting deployment binaries path..." -Diag
        $BinariesPath = $RegKey.BinariesPath
        if ($BinariesPath)
        {
            Write-Message "- Found deployment binaries path: $BinariesPath" -Diag
        }
        else
        {
            Write-Message "- No deployment binaries path found in registry." -Diag
        }
    }

    return $BinariesPath
}

<#
.SYNOPSIS
    Get the Dynamics AX deployment metadata path from Dynamics SDK registry key.

.NOTES
    Throws exception if the Dynamics SDK registry path is not found.

.OUTPUTS
    System.String. The full path to the deployment metadata.
#>
function Get-AX7SdkDeploymentMetadataPath
{
    [Cmdletbinding()]
    Param()

    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")

    [string]$MetadataPath = $null

    $RegPath = "HKLM:\SOFTWARE\Microsoft\Dynamics\AX\7.0\SDK"
    
    # Get the Dynamics SDK registry key (throws if not found).
    Write-Message "- Getting Dynamics SDK registry key..." -Diag
    $RegKey = Get-ItemProperty -Path $RegPath

    if ($RegKey -ne $null)
    {
        Write-Message "- Getting deployment metadata path..." -Diag
        $MetadataPath = $RegKey.MetadataPath
        if ($MetadataPath)
        {
            Write-Message "- Found deployment metadata path: $MetadataPath" -Diag
        }
        else
        {
            Write-Message "- No deployment metadata path found in registry." -Diag
        }
    }

    return $MetadataPath
}

<#
.SYNOPSIS
    Get the Dynamics AX deployment packages path from Dynamics SDK registry key.

.NOTES
    Throws exception if the Dynamics SDK registry path is not found.

.OUTPUTS
    System.String. The full path to the deployment packages.
#>
function Get-AX7SdkDeploymentPackagesPath
{
    [Cmdletbinding()]
    Param()

    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")

    [string]$PackagesPath = $null

    $RegPath = "HKLM:\SOFTWARE\Microsoft\Dynamics\AX\7.0\SDK"
    
    # Get the Dynamics SDK registry key (throws if not found).
    Write-Message "- Getting Dynamics SDK registry key..." -Diag
    $RegKey = Get-ItemProperty -Path $RegPath

    if ($RegKey -ne $null)
    {
        Write-Message "- Getting deployment packages path..." -Diag
        $PackagesPath = $RegKey.PackagesPath
        if ($PackagesPath)
        {
            Write-Message "- Found deployment packages path: $PackagesPath" -Diag
        }
        else
        {
            Write-Message "- No deployment packages path found in registry." -Diag
        }
    }

    return $PackagesPath
}

<#
.SYNOPSIS
    Stop the IIS service.
#>
function Stop-IIS
{
    [Cmdletbinding()]
    Param()
        
    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")

    Write-Message "- Calling IISReset /STOP to stop IIS..." -Diag

    $IISResetOutput = & IISReset /STOP
        
    # Check exit code to make sure the service was correctly removed.
    $IISResetExitCode = [int]$LASTEXITCODE
                
    # Log output if any.
    if ($IISResetOutput -and $IISResetOutput.Count -gt 0)
    {
        $IISResetOutput | % { Write-Message $_ -Diag }
    }

    Write-Message "- IISReset completed with exit code: $IISResetExitCode" -Diag
    if ($IISResetExitCode -ne 0)
	{
		throw "IISReset returned an unexpected exit code: $IISResetExitCode"
	}

    Write-Message "- IIS stopped successfully." -Diag
}

<#
.SYNOPSIS
    Start the IIS service.
#>
function Start-IIS
{
    [Cmdletbinding()]
    Param()
    
    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")

    Write-Message "- Calling IISReset /START to start IIS..." -Diag

    $IISResetOutput = & IISReset /START
        
    # Check exit code to make sure the service was correctly removed.
    $IISResetExitCode = [int]$LASTEXITCODE
                
    # Log output if any.
    if ($IISResetOutput -and $IISResetOutput.Count -gt 0)
    {
        $IISResetOutput | % { Write-Message $_ -Diag }
    }

    Write-Message "- IISReset completed with exit code: $IISResetExitCode" -Diag
    if ($IISResetExitCode -ne 0)
	{
		throw "IISReset returned an unexpected exit code: $IISResetExitCode"
	}

    Write-Message "- IIS started successfully." -Diag
}

<#
.SYNOPSIS
    Restart the IIS service.
#>
function Restart-IIS
{
    [Cmdletbinding()]
    Param()
    
    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")

    Write-Message "- Calling IISReset /RESTART to restart IIS..." -Diag
    
    $IISResetOutput = & IISReset /RESTART
    
    # Check exit code to make sure the service was correctly removed.
    $IISResetExitCode = [int]$LASTEXITCODE
    
    # Log output if any.
    if ($IISResetOutput -and $IISResetOutput.Count -gt 0)
    {
        $IISResetOutput | % { Write-Message $_ -Diag }
    }

    Write-Message "- IISReset completed with exit code: $IISResetExitCode" -Diag
    if ($IISResetExitCode -ne 0)
	{
		throw "IISReset returned an unexpected exit code: $IISResetExitCode"
	}

    Write-Message "- IIS restarted successfully." -Diag
}

<#
.SYNOPSIS
    Get the Dynamics AX 7.0 deployment AOS website path.

.DESCRIPTION
    If a website name is not specified it will try to use the default website
    name used by the deployment process.
#>
function Get-AX7DeploymentAosWebsite
{
    [Cmdletbinding()]
    Param([string]$WebsiteName)
    
    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")

    # Import only the functions needed (Too noisy with Verbose).
    Import-Module -Name "WebAdministration" -Function "Get-Website" -Verbose:$false

    [Microsoft.IIs.PowerShell.Framework.ConfigurationElement]$Website = $null

    if ($WebsiteName)
    {
        # Use specified website name.
        $Website = Get-Website -Name $WebsiteName
    }
    else
    {
        # Try default service model website name.
        $Website = Get-Website -Name "AosService"
        if (!$Website)
        {
            # Try default deploy website name.
            $Website = Get-Website -Name "AosWebApplication"
        }
    }

    return $Website
}

<#
.SYNOPSIS
    Get the Dynamics AX 7.0 deployment AOS website path.
#>
function Get-AX7DeploymentAosWebsitePath
{
    [Cmdletbinding()]
    Param([string]$WebsiteName)
    
    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")

    [string]$AosWebsitePath = $null

    # Get website and its physical path.
    $Website = Get-AX7DeploymentAosWebsite -WebsiteName $WebsiteName
    if ($Website)
    {
        $AosWebsitePath = $Website.physicalPath
    }
    else
    {
        throw "No AOS website could be found in IIS."
    }

    return $AosWebsitePath
}

<#
.SYNOPSIS
    Get the Dynamics AX 7.0 deployment AOS web config path.
#>
function Get-AX7DeploymentAosWebConfigPath
{
    [Cmdletbinding()]
    Param([string]$WebsiteName)
    
    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")

    [string]$AosWebConfigPath = $null

    [string]$AosWebsitePath = Get-AX7DeploymentAosWebsitePath -WebsiteName $WebsiteName

    if ($AosWebsitePath)
    {
        $AosWebConfigPath = Join-Path -Path $AosWebsitePath -ChildPath "web.config"
    }

    return $AosWebConfigPath
}

<#
.SYNOPSIS
    Get the Dynamics AX 7.0 deployment AOS wif config path.
#>
function Get-AX7DeploymentAosWifConfigPath
{
    [Cmdletbinding()]
    Param([string]$WebsiteName)
    
    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")
        
    [string]$AosWifConfigPath = $null

    [string]$AosWebsitePath = Get-AX7DeploymentAosWebsitePath -WebsiteName $WebsiteName

    if ($AosWebsitePath)
    {
        $AosWifConfigPath = Join-Path -Path $AosWebsitePath -ChildPath "wif.config"
    }

    return $AosWifConfigPath
}

<#
.SYNOPSIS
    Get the setting value from the specified web.config file path mathing
    the specified setting name.
#>
function Get-AX7DeploymentAosWebConfigSetting
{
    [Cmdletbinding()]
    Param([string]$WebConfigPath, [string]$Name)
    
    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")

    [string]$SettingValue = $null

    if (Test-Path -Path $WebConfigPath -PathType Leaf)
    {
        [xml]$WebConfig = Get-Content -Path $WebConfigPath
        if ($WebConfig)
        {
            $XPath = "/configuration/appSettings/add[@key='$($Name)']"
            $KeyNode = $WebConfig.SelectSingleNode($XPath)
            if ($KeyNode)
            {
                $SettingValue = $KeyNode.Value
            }
            else
            {
                throw "Failed to find setting in web.config at: $XPath"
            }
        }
        else
        {
            throw "Failed to read web.config content from: $WebConfigPath"
        }
    }
    else
    {
        throw "The specified web.config file could not be found at: $WebConfigPath"
    }

    return $SettingValue
}

<#
.SYNOPSIS
    Get the Dynamics AX 7.0 deployment binaries path.

.DESCRIPTION
    Value is extracted from the specified web.config file path of the default
    AOS web config if no web config path is specified.
#>
function Get-AX7DeploymentBinariesPath
{
    [Cmdletbinding()]
    Param([string]$WebConfigPath)
    
    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")

    [string]$BinariesPath = $null

    if (!$WebConfigPath)
    {
        $WebConfigPath = Get-AX7DeploymentAosWebConfigPath
    }
    # TODO: Correct this if Common.BinDir will ever be fixed to contain Bin.
    $BinariesPath = Get-AX7DeploymentAosWebConfigSetting -WebConfigPath $WebConfigPath -Name "Common.BinDir"
    if (!($BinariesPath -imatch "\\Bin$"))
    {
        $BinariesPath = Join-Path -Path $BinariesPath -ChildPath "Bin"
    }    

    return $BinariesPath
}

<#
.SYNOPSIS
    Get the Dynamics AX 7.0 deployment metadata path.

.DESCRIPTION
    Value is extracted from the specified web.config file path of the default
    AOS web config if no web config path is specified.
#>
function Get-AX7DeploymentMetadataPath
{
    [Cmdletbinding()]
    Param([string]$WebConfigPath)
    
    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")
        
    [string]$MetadataPath = $null

    if (!$WebConfigPath)
    {
        $WebConfigPath = Get-AX7DeploymentAosWebConfigPath
    }
    $MetadataPath = Get-AX7DeploymentAosWebConfigSetting -WebConfigPath $WebConfigPath -Name "Aos.MetadataDirectory"

    return $MetadataPath
}

<#
.SYNOPSIS
    Get the Dynamics AX 7.0 deployment packages path.

.DESCRIPTION
    Value is extracted from the specified web.config file path of the default
    AOS web config if no web config path is specified.
#>
function Get-AX7DeploymentPackagesPath
{
    [Cmdletbinding()]
    Param([string]$WebConfigPath)
    
    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")
        
    [string]$PackagesPath = $null

    if (!$WebConfigPath)
    {
        $WebConfigPath = Get-AX7DeploymentAosWebConfigPath
    }
    $PackagesPath = Get-AX7DeploymentAosWebConfigSetting -WebConfigPath $WebConfigPath -Name "Aos.PackageDirectory"

    return $PackagesPath
}

<#
.SYNOPSIS
    Get the Dynamics AX 7.0 deployment database name.

.DESCRIPTION
    Value is extracted from the specified web.config file path of the default
    AOS web config if no web config path is specified.
#>
function Get-AX7DeploymentDatabaseName
{
    [Cmdletbinding()]
    Param([string]$WebConfigPath)
    
    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")
        
    [string]$DatabaseName = $null

    if (!$WebConfigPath)
    {
        $WebConfigPath = Get-AX7DeploymentAosWebConfigPath
    }
    $DatabaseName = Get-AX7DeploymentAosWebConfigSetting -WebConfigPath $WebConfigPath -Name "DataAccess.Database"

    return $DatabaseName
}

<#
.SYNOPSIS
    Get the Dynamics AX 7.0 deployment database server.

.DESCRIPTION
    Value is extracted from the specified web.config file path of the default
    AOS web config if no web config path is specified.
#>
function Get-AX7DeploymentDatabaseServer
{
    [Cmdletbinding()]
    Param([string]$WebConfigPath)
    
    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")
        
    [string]$DatabaseServer = $null

    if (!$WebConfigPath)
    {
        $WebConfigPath = Get-AX7DeploymentAosWebConfigPath
    }
    $DatabaseServer = Get-AX7DeploymentAosWebConfigSetting -WebConfigPath $WebConfigPath -Name "DataAccess.DbServer"

    return $DatabaseServer
}

<#
.SYNOPSIS
    Stop the Dynamics AX 7.0 deployment AOS website.
#>
function Stop-AX7DeploymentAosWebsite
{
    [Cmdletbinding()]
    Param([string]$WebsiteName)
    
    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")

    # Get website and stop it if not already stopped.
    $Website = Get-AX7DeploymentAosWebsite -WebsiteName $WebsiteName
    if ($Website)
    {
        Write-Message "- AOS website state: $($Website.State)" -Diag

        # State is empty if IIS is not running in which case the website is already stopped.
        if ($Website.State -and $Website.State -ine "Stopped")
        {
            Write-Message "- Stopping AOS website..." -Diag
            $Website.Stop()
            Write-Message "- AOS website state after stop: $($Website.State)" -Diag
        }
    }

    # If IIS Express instances are running, stop those
    $expressSites = Get-Process | Where-Object { $_.Name -eq "iisexpress" }
    if ($expressSites.Length -gt 0)
    {
        Write-Message "- Stopping IIS Express instances"
        foreach($site in $expressSites)
        {
            Stop-Process $site -Force
        }
        Write-Message "- IIS Express instances stopped"
    }
}

<#
.SYNOPSIS
    Start the Dynamics AX 7.0 deployment AOS website.
#>
function Start-AX7DeploymentAosWebsite
{
    [Cmdletbinding()]
    Param([string]$WebsiteName)

    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")

    # Get website and start it if not already started.
    $Website = Get-AX7DeploymentAosWebsite -WebsiteName $WebsiteName
    if ($Website)
    {
        Write-Message "- AOS website state: $($Website.State)" -Diag
        # State is empty if IIS is not running.
        if (!($Website.State))
        {
            Start-IIS
            Write-Message "- AOS website state after IIS start: $($Website.State)" -Diag
        }

        if ($Website.State -and $Website.State -ine "Started")
        {
            Write-Message "- Starting AOS website..." -Diag
            $Website.Start()
            Write-Message "- AOS website state after start: $($Website.State)" -Diag
        }
    }
}

<#
.SYNOPSIS
    Stop the Dynamics AX 7.0 services and IIS.
#>
function Stop-AX7Deployment
{
    [Cmdletbinding()]
    Param([int]$ServiceStopWaitSec = 30, [int]$ProcessStopWaitSec = 30)

    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")

    # There are a number of Dynamics web sites. Safer to stop IIS completely.
    Stop-IIS

    $DynamicsServiceNames = @("DynamicsAxBatch", "Microsoft.Dynamics.AX.Framework.Tools.DMF.SSISHelperService.exe", "MR2012ProcessService")
    foreach ($DynamicsServiceName in $DynamicsServiceNames)
    {
        $Service = Get-Service -Name $DynamicsServiceName -ErrorAction SilentlyContinue
        if ($Service)
        {
            if ($Service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped)
            {
                # Get the service process ID to track if it has exited when the service has stopped.
                [UInt32]$ServiceProcessId = 0
                $WmiService = Get-WmiObject -Class Win32_Service -Filter "Name = '$($Service.ServiceName)'" -ErrorAction SilentlyContinue
                if ($WmiService)
                {
                    if ($WmiService.ProcessId -gt $ServiceProcessId)
                    {
                        $ServiceProcessId = $WmiService.ProcessId
                        Write-Message "- The $($DynamicsServiceName) service has process ID: $ServiceProcessId" -Diag
                    }
                    else
                    {
                        Write-Message "- The $($DynamicsServiceName) service does not have a process ID." -Diag
                    }
                }
                else
                {
                    Write-Message "- No $($Service.ServiceName) service found through WMI. Cannot get process ID of the service." -Warning
                }

                # Signal the service to stop.
                Write-Message "- Stopping the $($DynamicsServiceName) service (Status: $($Service.Status))..." -Diag
                Stop-Service -Name $DynamicsServiceName

                # Wait for the service to stop.
                if ($ServiceStopWaitSec -gt 0)
                {
                    Write-Message "- Waiting up to $($ServiceStopWaitSec) seconds for the $($DynamicsServiceName) service to stop (Status: $($Service.Status))..." -Diag
                    # This will throw a System.ServiceProcess.TimeoutException if the stopped state is not reached within the timeout.
                    $Service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds($ServiceStopWaitSec))
                    Write-Message "- The $($DynamicsServiceName) service has been stopped (Status: $($Service.Status))." -Diag
                }

                # Wait for the process, if any was found, to exit.
                if ($ProcessStopWaitSec -gt 0 -and $ServiceProcessId -gt 0)
                {
                    # If the process is found, wait for it to exit.
                    $ServiceProcess = Get-Process -Id $ServiceProcessId -ErrorAction SilentlyContinue
                    if ($ServiceProcess)
                    {
                        Write-Message "- Waiting up to $($ProcessStopWaitSec) seconds for the $($DynamicsServiceName) service process ID $($ServiceProcessId) to exit..." -Diag
                        # This will throw a System.TimeoutException if the process does not exit within the timeout.
                        Wait-Process -Id $ServiceProcessId -Timeout $ProcessStopWaitSec
                    }
                    Write-Message "- The $($DynamicsServiceName) service process ID $($ServiceProcessId) has exited." -Diag
                }
            }
            else
            {
                Write-Message "- The $($DynamicsServiceName) service is already stopped." -Diag
            }
        }
        else
        {
            Write-Message "- No $($DynamicsServiceName) service found." -Diag
        }
    }
}

<#
.SYNOPSIS
    Start the Dynamics AX 7.0 deployment services and IIS.
#>
function Start-AX7Deployment
{
    [Cmdletbinding()]
    Param()

    # Get verbose preference from caller.
    $VerbosePreference = $PSCmdlet.GetVariableValue("VerbosePreference")

    $DynamicsServiceNames = @("DynamicsAxBatch", "Microsoft.Dynamics.AX.Framework.Tools.DMF.SSISHelperService.exe", "MR2012ProcessService")
    foreach ($DynamicsServiceName in $DynamicsServiceNames)
    {
        $Service = Get-Service -Name $DynamicsServiceName -ErrorAction SilentlyContinue
        if ($Service)
        {
            if ($Service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Running)
            {
                Write-Message "- Starting $($DynamicsServiceName) service..." -Diag
                Start-Service -Name $DynamicsServiceName
                Write-Message "- $($DynamicsServiceName) service successfully started." -Diag
            }
            else
            {
                Write-Message "- $($DynamicsServiceName) service is already running." -Diag
            }
        }
        else
        {
            Write-Message "- No $($DynamicsServiceName) service found." -Diag
        }
    }

    # Start IIS back up.
    Start-IIS
}

# Functions to export from this module (sorted alphabetically).
$ExportFunctions = @(
    "Get-AX7DeploymentAosWebConfigPath",
    "Get-AX7DeploymentAosWifConfigPath",
    "Get-AX7SdkBackupPath",
    "Get-AX7SdkDeploymentAosWebsiteName",
    "Get-AX7SdkDeploymentBinariesPath",
    "Get-AX7SdkDeploymentDatabaseName",
    "Get-AX7SdkDeploymentDatabaseServer",
    "Get-AX7SdkDeploymentMetadataPath",
    "Get-AX7SdkDeploymentPackagesPath",
    "Get-AX7SdkPath",
    "Get-AX7SdkTeamFoundationServerUrl",
    "Set-AX7SdkEnvironmentVariables",
    "Set-AX7SdkRegistryValues",
    "Set-AX7SdkRegistryValuesFromAosWebConfig",
    "Start-AX7Deployment",
    "Start-AX7DeploymentAosWebsite",
    "Stop-AX7Deployment",
    "Stop-AX7DeploymentAosWebsite",
    "Write-Message"
)

Export-ModuleMember -Function $ExportFunctions
# SIG # Begin signature block
# MIIjnwYJKoZIhvcNAQcCoIIjkDCCI4wCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBfn7ZIHE/dU5JQ
# FRh8xGVvtqdkDd/YaMWaWJ3CN9H7pKCCDYEwggX/MIID56ADAgECAhMzAAAB32vw
# LpKnSrTQAAAAAAHfMA0GCSqGSIb3DQEBCwUAMH4xCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25p
# bmcgUENBIDIwMTEwHhcNMjAxMjE1MjEzMTQ1WhcNMjExMjAyMjEzMTQ1WjB0MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYDVQQDExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB
# AQC2uxlZEACjqfHkuFyoCwfL25ofI9DZWKt4wEj3JBQ48GPt1UsDv834CcoUUPMn
# s/6CtPoaQ4Thy/kbOOg/zJAnrJeiMQqRe2Lsdb/NSI2gXXX9lad1/yPUDOXo4GNw
# PjXq1JZi+HZV91bUr6ZjzePj1g+bepsqd/HC1XScj0fT3aAxLRykJSzExEBmU9eS
# yuOwUuq+CriudQtWGMdJU650v/KmzfM46Y6lo/MCnnpvz3zEL7PMdUdwqj/nYhGG
# 3UVILxX7tAdMbz7LN+6WOIpT1A41rwaoOVnv+8Ua94HwhjZmu1S73yeV7RZZNxoh
# EegJi9YYssXa7UZUUkCCA+KnAgMBAAGjggF+MIIBejAfBgNVHSUEGDAWBgorBgEE
# AYI3TAgBBggrBgEFBQcDAzAdBgNVHQ4EFgQUOPbML8IdkNGtCfMmVPtvI6VZ8+Mw
# UAYDVR0RBEkwR6RFMEMxKTAnBgNVBAsTIE1pY3Jvc29mdCBPcGVyYXRpb25zIFB1
# ZXJ0byBSaWNvMRYwFAYDVQQFEw0yMzAwMTIrNDYzMDA5MB8GA1UdIwQYMBaAFEhu
# ZOVQBdOCqhc3NyK1bajKdQKVMFQGA1UdHwRNMEswSaBHoEWGQ2h0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY0NvZFNpZ1BDQTIwMTFfMjAxMS0w
# Ny0wOC5jcmwwYQYIKwYBBQUHAQEEVTBTMFEGCCsGAQUFBzAChkVodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY0NvZFNpZ1BDQTIwMTFfMjAx
# MS0wNy0wOC5jcnQwDAYDVR0TAQH/BAIwADANBgkqhkiG9w0BAQsFAAOCAgEAnnqH
# tDyYUFaVAkvAK0eqq6nhoL95SZQu3RnpZ7tdQ89QR3++7A+4hrr7V4xxmkB5BObS
# 0YK+MALE02atjwWgPdpYQ68WdLGroJZHkbZdgERG+7tETFl3aKF4KpoSaGOskZXp
# TPnCaMo2PXoAMVMGpsQEQswimZq3IQ3nRQfBlJ0PoMMcN/+Pks8ZTL1BoPYsJpok
# t6cql59q6CypZYIwgyJ892HpttybHKg1ZtQLUlSXccRMlugPgEcNZJagPEgPYni4
# b11snjRAgf0dyQ0zI9aLXqTxWUU5pCIFiPT0b2wsxzRqCtyGqpkGM8P9GazO8eao
# mVItCYBcJSByBx/pS0cSYwBBHAZxJODUqxSXoSGDvmTfqUJXntnWkL4okok1FiCD
# Z4jpyXOQunb6egIXvkgQ7jb2uO26Ow0m8RwleDvhOMrnHsupiOPbozKroSa6paFt
# VSh89abUSooR8QdZciemmoFhcWkEwFg4spzvYNP4nIs193261WyTaRMZoceGun7G
# CT2Rl653uUj+F+g94c63AhzSq4khdL4HlFIP2ePv29smfUnHtGq6yYFDLnT0q/Y+
# Di3jwloF8EWkkHRtSuXlFUbTmwr/lDDgbpZiKhLS7CBTDj32I0L5i532+uHczw82
# oZDmYmYmIUSMbZOgS65h797rj5JJ6OkeEUJoAVwwggd6MIIFYqADAgECAgphDpDS
# AAAAAAADMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0
# ZSBBdXRob3JpdHkgMjAxMTAeFw0xMTA3MDgyMDU5MDlaFw0yNjA3MDgyMTA5MDla
# MH4xCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMT
# H01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMTEwggIiMA0GCSqGSIb3DQEB
# AQUAA4ICDwAwggIKAoICAQCr8PpyEBwurdhuqoIQTTS68rZYIZ9CGypr6VpQqrgG
# OBoESbp/wwwe3TdrxhLYC/A4wpkGsMg51QEUMULTiQ15ZId+lGAkbK+eSZzpaF7S
# 35tTsgosw6/ZqSuuegmv15ZZymAaBelmdugyUiYSL+erCFDPs0S3XdjELgN1q2jz
# y23zOlyhFvRGuuA4ZKxuZDV4pqBjDy3TQJP4494HDdVceaVJKecNvqATd76UPe/7
# 4ytaEB9NViiienLgEjq3SV7Y7e1DkYPZe7J7hhvZPrGMXeiJT4Qa8qEvWeSQOy2u
# M1jFtz7+MtOzAz2xsq+SOH7SnYAs9U5WkSE1JcM5bmR/U7qcD60ZI4TL9LoDho33
# X/DQUr+MlIe8wCF0JV8YKLbMJyg4JZg5SjbPfLGSrhwjp6lm7GEfauEoSZ1fiOIl
# XdMhSz5SxLVXPyQD8NF6Wy/VI+NwXQ9RRnez+ADhvKwCgl/bwBWzvRvUVUvnOaEP
# 6SNJvBi4RHxF5MHDcnrgcuck379GmcXvwhxX24ON7E1JMKerjt/sW5+v/N2wZuLB
# l4F77dbtS+dJKacTKKanfWeA5opieF+yL4TXV5xcv3coKPHtbcMojyyPQDdPweGF
# RInECUzF1KVDL3SV9274eCBYLBNdYJWaPk8zhNqwiBfenk70lrC8RqBsmNLg1oiM
# CwIDAQABo4IB7TCCAekwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFEhuZOVQ
# BdOCqhc3NyK1bajKdQKVMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMAsGA1Ud
# DwQEAwIBhjAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFHItOgIxkEO5FAVO
# 4eqnxzHRI4k0MFoGA1UdHwRTMFEwT6BNoEuGSWh0dHA6Ly9jcmwubWljcm9zb2Z0
# LmNvbS9wa2kvY3JsL3Byb2R1Y3RzL01pY1Jvb0NlckF1dDIwMTFfMjAxMV8wM18y
# Mi5jcmwwXgYIKwYBBQUHAQEEUjBQME4GCCsGAQUFBzAChkJodHRwOi8vd3d3Lm1p
# Y3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jvb0NlckF1dDIwMTFfMjAxMV8wM18y
# Mi5jcnQwgZ8GA1UdIASBlzCBlDCBkQYJKwYBBAGCNy4DMIGDMD8GCCsGAQUFBwIB
# FjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2RvY3MvcHJpbWFyeWNw
# cy5odG0wQAYIKwYBBQUHAgIwNB4yIB0ATABlAGcAYQBsAF8AcABvAGwAaQBjAHkA
# XwBzAHQAYQB0AGUAbQBlAG4AdAAuIB0wDQYJKoZIhvcNAQELBQADggIBAGfyhqWY
# 4FR5Gi7T2HRnIpsLlhHhY5KZQpZ90nkMkMFlXy4sPvjDctFtg/6+P+gKyju/R6mj
# 82nbY78iNaWXXWWEkH2LRlBV2AySfNIaSxzzPEKLUtCw/WvjPgcuKZvmPRul1LUd
# d5Q54ulkyUQ9eHoj8xN9ppB0g430yyYCRirCihC7pKkFDJvtaPpoLpWgKj8qa1hJ
# Yx8JaW5amJbkg/TAj/NGK978O9C9Ne9uJa7lryft0N3zDq+ZKJeYTQ49C/IIidYf
# wzIY4vDFLc5bnrRJOQrGCsLGra7lstnbFYhRRVg4MnEnGn+x9Cf43iw6IGmYslmJ
# aG5vp7d0w0AFBqYBKig+gj8TTWYLwLNN9eGPfxxvFX1Fp3blQCplo8NdUmKGwx1j
# NpeG39rz+PIWoZon4c2ll9DuXWNB41sHnIc+BncG0QaxdR8UvmFhtfDcxhsEvt9B
# xw4o7t5lL+yX9qFcltgA1qFGvVnzl6UJS0gQmYAf0AApxbGbpT9Fdx41xtKiop96
# eiL6SJUfq/tHI4D1nvi/a7dLl+LrdXga7Oo3mXkYS//WsyNodeav+vyL6wuA6mk7
# r/ww7QRMjt/fdW1jkT3RnVZOT7+AVyKheBEyIXrvQQqxP/uozKRdwaGIm1dxVk5I
# RcBCyZt2WwqASGv9eZ/BvW1taslScxMNelDNMYIVdDCCFXACAQEwgZUwfjELMAkG
# A1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQx
# HjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9z
# b2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAxMQITMwAAAd9r8C6Sp0q00AAAAAAB3zAN
# BglghkgBZQMEAgEFAKCBrjAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgor
# BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgHzV5mQhH
# NinDsBVsH6mXVZA41hEHBBdPRuSMbB0edi8wQgYKKwYBBAGCNwIBDDE0MDKgFIAS
# AE0AaQBjAHIAbwBzAG8AZgB0oRqAGGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbTAN
# BgkqhkiG9w0BAQEFAASCAQB9HD0yVvNvQi6m3xF8chuTGSnLgoTBYNbPRyFh+pcv
# Nth/g5YFpRgXUdLc/nJUnA2Y1v8a5f6CYds5V65EXIuqmFJFW1E+lGZ56F+yU0/K
# IVGxY1Sqi0TUfSrLN0V25CtVp8N61CjB5OFXH0hM2pH7RwQQKn+YkhGe+stmlfxU
# ja8alxJOnM63i/co/bv1g1Gh6P8LnsgNYPJAHD8D1ySiOzeT7I6d5HkP6YIT+9XG
# ksw6IqWYwzaAJe/Gi1/SRo/2BUIet9Hg4r0UszlLeCkSc++ODdQa3EMF0PWGNXYt
# wtZjVX609znxX/BeMRxsoMbe5HDcP1d2zcMOeGV/ZhQMoYIS/jCCEvoGCisGAQQB
# gjcDAwExghLqMIIS5gYJKoZIhvcNAQcCoIIS1zCCEtMCAQMxDzANBglghkgBZQME
# AgEFADCCAVkGCyqGSIb3DQEJEAEEoIIBSASCAUQwggFAAgEBBgorBgEEAYRZCgMB
# MDEwDQYJYIZIAWUDBAIBBQAEIDel7LG+5yjcyMeb+pEUXl74M1RK9AbAvejLP+vh
# yZtYAgZgPN+tEjsYEzIwMjEwMzAzMDMxMDAwLjY3N1owBIACAfSggdikgdUwgdIx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1p
# Y3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEmMCQGA1UECxMdVGhh
# bGVzIFRTUyBFU046RTA0MS00QkVFLUZBN0UxJTAjBgNVBAMTHE1pY3Jvc29mdCBU
# aW1lLVN0YW1wIFNlcnZpY2Wggg5NMIIE+TCCA+GgAwIBAgITMwAAATdBj0PnWltv
# pwAAAAABNzANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0Eg
# MjAxMDAeFw0yMDEwMTUxNzI4MTRaFw0yMjAxMTIxNzI4MTRaMIHSMQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQg
# SXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxJjAkBgNVBAsTHVRoYWxlcyBUU1Mg
# RVNOOkUwNDEtNEJFRS1GQTdFMSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFt
# cCBTZXJ2aWNlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxBHuadEl
# m3G5tikhTzjSDB0+9sXmUhUyDVRj0Y4vz9rZ9sykNobL5/6At5zOkeB2bl9IXvVd
# yS/ZJNZT373knzrQ347z30Mmw7++VU/CE+4x4w9kb5bqQHfSzbJQt6KmWsuMmJLz
# g4R5MeJs5MY5YdPLxoMoDRcTi//KoMFR0KzS1/324D2/4KkHD1Xt+s0xY0DICUOK
# 1RbmJCKEgBP1/GDZjuZQBS9Di89yTnvLJV+Lr1QtriH4EqmRoAdmV3zJ0GJsr5vh
# GPmKfOPCRSk7Q8igX7goFnCLzpYcfHGCqoR/mw95gfQpwymVwxZB0PkGMrQw+LKV
# Pa/FHP4C4KO+QQIDAQABo4IBGzCCARcwHQYDVR0OBBYEFA1gsHMM+udgY7rEne66
# OyzxlE9lMB8GA1UdIwQYMBaAFNVjOlyKMZDzQ3t8RhvFM2hahW1VMFYGA1UdHwRP
# ME0wS6BJoEeGRWh0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1
# Y3RzL01pY1RpbVN0YVBDQV8yMDEwLTA3LTAxLmNybDBaBggrBgEFBQcBAQROMEww
# SgYIKwYBBQUHMAKGPmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMv
# TWljVGltU3RhUENBXzIwMTAtMDctMDEuY3J0MAwGA1UdEwEB/wQCMAAwEwYDVR0l
# BAwwCgYIKwYBBQUHAwgwDQYJKoZIhvcNAQELBQADggEBAJ32U9d90RVuAUb9NsnX
# BG1K42qjhU+jHvwBdbipIcX4Wg7dH5ZduQZj3gWgKADZ5z+TehX7GnBbi265VI7x
# DRsFe2CjkTm4JIoisdKwYBDruS+YRRBG4B1ERuWi54XGwx+lSA+iQNrIi6Jm0CL/
# MfQLvwsqPJSGP69OEHCyaExos486+X3JTuGV11CBl/BO7r8UHbx/rE6fZrlZZYab
# IF6aeahvTL14LvZLV/bMzYSODsbjHHsTm9QaGm1ijhagCdbkAqr8+7HAgYEar8XP
# lzxUhVI4ShVB5ZGd9gZ2yBkwxdA0oFc745TdOPrbP79vd0ePqgvJDH5tkOhTRNI5
# 5XQwggZxMIIEWaADAgECAgphCYEqAAAAAAACMA0GCSqGSIb3DQEBCwUAMIGIMQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNy
# b3NvZnQgUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAxMDAeFw0xMDA3MDEy
# MTM2NTVaFw0yNTA3MDEyMTQ2NTVaMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAy
# MDEwMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAqR0NvHcRijog7PwT
# l/X6f2mUa3RUENWlCgCChfvtfGhLLF/Fw+Vhwna3PmYrW/AVUycEMR9BGxqVHc4J
# E458YTBZsTBED/FgiIRUQwzXTbg4CLNC3ZOs1nMwVyaCo0UN0Or1R4HNvyRgMlhg
# RvJYR4YyhB50YWeRX4FUsc+TTJLBxKZd0WETbijGGvmGgLvfYfxGwScdJGcSchoh
# iq9LZIlQYrFd/XcfPfBXday9ikJNQFHRD5wGPmd/9WbAA5ZEfu/QS/1u5ZrKsajy
# eioKMfDaTgaRtogINeh4HLDpmc085y9Euqf03GS9pAHBIAmTeM38vMDJRF1eFpwB
# BU8iTQIDAQABo4IB5jCCAeIwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFNVj
# OlyKMZDzQ3t8RhvFM2hahW1VMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMAsG
# A1UdDwQEAwIBhjAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFNX2VsuP6KJc
# YmjRPZSQW9fOmhjEMFYGA1UdHwRPME0wS6BJoEeGRWh0dHA6Ly9jcmwubWljcm9z
# b2Z0LmNvbS9wa2kvY3JsL3Byb2R1Y3RzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIz
# LmNybDBaBggrBgEFBQcBAQROMEwwSgYIKwYBBQUHMAKGPmh0dHA6Ly93d3cubWlj
# cm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3J0
# MIGgBgNVHSABAf8EgZUwgZIwgY8GCSsGAQQBgjcuAzCBgTA9BggrBgEFBQcCARYx
# aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL1BLSS9kb2NzL0NQUy9kZWZhdWx0Lmh0
# bTBABggrBgEFBQcCAjA0HjIgHQBMAGUAZwBhAGwAXwBQAG8AbABpAGMAeQBfAFMA
# dABhAHQAZQBtAGUAbgB0AC4gHTANBgkqhkiG9w0BAQsFAAOCAgEAB+aIUQ3ixuCY
# P4FxAz2do6Ehb7Prpsz1Mb7PBeKp/vpXbRkws8LFZslq3/Xn8Hi9x6ieJeP5vO1r
# VFcIK1GCRBL7uVOMzPRgEop2zEBAQZvcXBf/XPleFzWYJFZLdO9CEMivv3/Gf/I3
# fVo/HPKZeUqRUgCvOA8X9S95gWXZqbVr5MfO9sp6AG9LMEQkIjzP7QOllo9ZKby2
# /QThcJ8ySif9Va8v/rbljjO7Yl+a21dA6fHOmWaQjP9qYn/dxUoLkSbiOewZSnFj
# nXshbcOco6I8+n99lmqQeKZt0uGc+R38ONiU9MalCpaGpL2eGq4EQoO4tYCbIjgg
# tSXlZOz39L9+Y1klD3ouOVd2onGqBooPiRa6YacRy5rYDkeagMXQzafQ732D8OE7
# cQnfXXSYIghh2rBQHm+98eEA3+cxB6STOvdlR3jo+KhIq/fecn5ha293qYHLpwms
# ObvsxsvYgrRyzR30uIUBHoD7G4kqVDmyW9rIDVWZeodzOwjmmC3qjeAzLhIp9cAv
# VCch98isTtoouLGp25ayp0Kiyc8ZQU3ghvkqmqMRZjDTu3QyS99je/WZii8bxyGv
# WbWu3EQ8l1Bx16HSxVXjad5XwdHeMMD9zOZN+w2/XU/pnR4ZOC+8z1gFLu8NoFA1
# 2u8JJxzVs341Hgi62jbb01+P3nSISRKhggLXMIICQAIBATCCAQChgdikgdUwgdIx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1p
# Y3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEmMCQGA1UECxMdVGhh
# bGVzIFRTUyBFU046RTA0MS00QkVFLUZBN0UxJTAjBgNVBAMTHE1pY3Jvc29mdCBU
# aW1lLVN0YW1wIFNlcnZpY2WiIwoBATAHBgUrDgMCGgMVAOq7qDk4iVz8ITuZbUFr
# AG7ecxqcoIGDMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
# b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwDQYJ
# KoZIhvcNAQEFBQACBQDj6VhWMCIYDzIwMjEwMzAzMDgzNTM0WhgPMjAyMTAzMDQw
# ODM1MzRaMHcwPQYKKwYBBAGEWQoEATEvMC0wCgIFAOPpWFYCAQAwCgIBAAICF6AC
# Af8wBwIBAAICEXMwCgIFAOPqqdYCAQAwNgYKKwYBBAGEWQoEAjEoMCYwDAYKKwYB
# BAGEWQoDAqAKMAgCAQACAwehIKEKMAgCAQACAwGGoDANBgkqhkiG9w0BAQUFAAOB
# gQBrRyhnYcvQvbEm9taA3AQ21M95lRKHAjhhhNRKC/RHOopSB5fo3rSUPY8egpp5
# Tuvpk9y0w5dCianvPKRhfOU0IjlHzwey+NzgCNMOLFb2gz26OWqjsbb5/gkV1DTC
# xxgssBc9DqXbhyUeQu+2oYiOk61DVUw/O0mG/Fd6BbuKzzGCAw0wggMJAgEBMIGT
# MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMT
# HU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAABN0GPQ+daW2+nAAAA
# AAE3MA0GCWCGSAFlAwQCAQUAoIIBSjAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQ
# AQQwLwYJKoZIhvcNAQkEMSIEICeY1NIcQe6Gypc/fnr1XXftf5VSoPxB77+uw5Nz
# BXycMIH6BgsqhkiG9w0BCRACLzGB6jCB5zCB5DCBvQQgHVl+r8CeBJ0iyX/aGZD2
# YbQ7gk+U7N7BQiTDKAYSHBAwgZgwgYCkfjB8MQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQ
# Q0EgMjAxMAITMwAAATdBj0PnWltvpwAAAAABNzAiBCAi65JPa6/l/RvHv8jkVUIE
# Laur+CfHdrhP7d4NaYF+fTANBgkqhkiG9w0BAQsFAASCAQBT7W/dxZwG1gnX/js6
# 3hD0Lk8yvVwhWQhBLNqhQhIH9cGYqV6OKk7hqURXkrbuDv+LIVlazN+OwV1dTLYS
# VXFQMXCE9U518V2h6Z7JVlm4MjBqFHqyXDqSTtDQzZgIIRocFSYzxlzBswZVIMEP
# uqr8RmGyZzE0rr8U5hUzqLI/0OWU9DsKj+0H4ltaMW5Vsf8fcnwz8IOUevY0gfWz
# ZFcbI9M6QF6na6A4gjM4D32t9tOZ8RccWJRLTMEtj1FVNJqjZke9V7ijzEU4Gcwb
# m11TcVixUtuLG29g4sdXyjAPbHidZnbhUNbsMCAjY1G6bYua6G/BeojU60juEj1Q
# Ksnw
# SIG # End signature block
