<#
.SYNOPSIS
    Configure the computer as a Visual Studio Team Services Agent for the
    specified VSTS project collection.

.DESCRIPTION
    This script is intended for use in the Dynamics AX Development setup
    process to install and configure the build agent service.

.NOTES
    When running through automation, use the -LogPath option to redirect
    output to a log file rather than the console. Requires PowerShell
    Community Extensions (PSCX).

    Copyright © 2016 Microsoft. All rights reserved.
#>
[Cmdletbinding()]
Param(
    [Parameter(Mandatory=$true, HelpMessage="The Visual Studio Team Services project collection URL to connect to.")]
    [string]$VSO_ProjectCollection,

    [Parameter(Mandatory=$false, HelpMessage="The user name to authenticate to Visual Studio Team Services. Deprecated - Please use VSOAccessToken.")]
    [string]$AlternateUsername,
    
    [Parameter(Mandatory=$false, HelpMessage="The password of the user to authenticate to Visual Studio Team Services. Deprecated - Please use VSOAccessToken.")]
    [string]$AlternatePassword,
    
    [Parameter(Mandatory=$false, HelpMessage="The full path to the file to write output to (If not specified the output will be written to the host).")]
    [string]$LogPath=$null,

    [Parameter(Mandatory=$false, HelpMessage="The VSTS Agent service account.")]
    [string]$ServiceAccountName="NT AUTHORITY\SYSTEM",

    [Parameter(Mandatory=$false, HelpMessage="The VSTS Agent service account password.")]
    [string]$ServiceAccountPassword="password",
    
    [Parameter(Mandatory=$false, HelpMessage="The VSTS Agent service name.")]
    [Alias("BuildAgent")]
    [string]$AgentName="VSTSAgent-$($env:COMPUTERNAME)",

    [Parameter(Mandatory=$false, HelpMessage="The VSTS Agent service display name.")]
    [string]$AgentDisplayName="VSTS Agent - $($env:COMPUTERNAME)",

    [Parameter(Mandatory=$false, HelpMessage="The VSTS Agent pool name.")]
    [string]$AgentPoolName="Default",

    [Parameter(Mandatory=$false, HelpMessage="The VSTS Agent work folder.")]
    [string]$AgentWorkFolder=$null,

    [Parameter(Mandatory=$false, HelpMessage="The VSTS access token to use for downloading and configuring the VSTS Agent.")]
    [string]$VSOAccessToken=$null,

    [Parameter(Mandatory=$false, HelpMessage="The Dynamics SDK path.")]
    [string]$DynamicsSdkPath="$($env:SystemDrive)\DynamicsSDK",

    [Parameter(Mandatory=$false, HelpMessage="The Dynamics AX AOS website name.")]
    [string]$AosWebsiteName="AosService",

    [Parameter(Mandatory=$false, HelpMessage="Remove the VSTS Agent if installed.")]
    [switch]$RemoveOnly,

    [Parameter(Mandatory=$false, HelpMessage="Download and expand the VSTS Agent archive even if it already exists.")]
    [switch]$Force,

    [Parameter(Mandatory=$false, HelpMessage="Throw an exception if an error occurs rather than returning a non-zero exit code.")]
    [switch]$ThrowOnError
)

# Import module for Write-Message and other common functions (Picks up $LogPath variable).
Import-Module $(Join-Path -Path $PSScriptRoot -ChildPath "DynamicsSDKCommon.psm1") -Function "Write-Message", "Set-AX7SdkRegistryValues", "Set-AX7SdkEnvironmentVariables"

<#
.SYNOPSIS
    Download the VSTS Agent archive.
#>
function Download-VSTSAgent([string]$ProjectCollection, [string]$AgentArchivePath, [int]$MaxAttempts = 10, [int]$RetryWaitSec = 30, [switch]$Force)
{
    [bool]$DownloadCompleted = $false

    [Uri]$AgentSource = Get-VSTSAgentDownloadURL $ProjectCollection

    Write-Message "- Downloading agent from $($AgentSource) to $($AgentArchivePath)..." -Diag

    if (Test-Path -Path $AgentArchivePath -PathType Leaf -ErrorAction SilentlyContinue)
    {
        if ($Force)
        {
            Write-Message "- Removing existing agent from: $AgentArchivePath" -Diag
            Remove-Item -Path $AgentArchivePath -Force
        }
        else
        {
            Write-Message "- Found existing agent archive. No new download will be attempted." -Diag
            $DownloadCompleted = $true
        }
    }
    else
    {
        # Ensure that the download path exists.
        $DownloadPath = Split-Path -Path $AgentArchivePath -Parent
        if (!(Test-Path -Path $DownloadPath -ErrorAction SilentlyContinue))
        {
            Write-Message "- Creating download path: $DownloadPath" -Diag
            $NewPath = New-Item -Path $DownloadPath -ItemType Container -Force
        }
    }
    
    [string]$AuthorizationHeaders = Get-VSTSRestAuthorization
    [int]$Attempt = 1
    [System.Net.WebClient]$WebClient = $null
    while (!$DownloadCompleted -and $Attempt -le $MaxAttempts)
    {
        try
        {
            $WebClient = New-Object System.Net.WebClient
            $WebClient.Headers['Authorization'] = $AuthorizationHeaders
            $WebClient.Headers['Accept'] = "application/octet-stream"

            Write-Message "- Download starting..." -Diag
            $DownloadStartTime = Get-Date
            $WebClient.DownloadFile($AgentSource, $AgentArchivePath)
            $DownloadEndTime = Get-Date
            Write-Message "- Download completed in $([int]$DownloadEndTime.Subtract($DownloadStartTime).TotalSeconds) seconds." -Diag

            # WebClient does not expose a response status code field, but will throw a
            # WebException if a non-OK status code is returned. When no exception is thrown,
            # Check the response headers to see if a non-application/zip file was downloaded
            # and if so throw an exception. This can happen if there is a problem with
            # authentication and the request is redirected to a login page which gets downloaded.
            #
            # Expected headers:
            # Content-Type = application/zip; api-version=2.1
            # Content-Disposition = attachment; filename=agent.zip; filename*=utf-8''agent.zip
            # Content-Length is not set.
            #
            # Authentication problem headers:
            # Content-Type = text/html; charset=utf-8
            # Content-Disposition is not set.
            # Content-Length = 22382
            if ($WebClient.ResponseHeaders -and $WebClient.ResponseHeaders.Count -gt 0)
            {
                $IsApplicationZip = $true
                Write-Message "- Response Headers:" -Diag
                foreach ($Key in $WebClient.ResponseHeaders.Keys)
                {
                    $Value = $WebClient.ResponseHeaders.Get($Key)
                    Write-Message "  - $($Key) = $($Value)" -Diag
                    if ($Key -ieq "Content-Type" -and $Value -inotmatch "application/octet-stream")
                    {
                        $IsApplicationZip = $false
                    }
                }

                if (!$IsApplicationZip)
                {
                    throw "Response content type from downloading agent archive is not application/zip. Check if specified access token is valid."
                }
            }

            if (Test-Path -Path $AgentArchivePath -PathType Leaf -ErrorAction SilentlyContinue)
            {
                Write-Message "- Unblocking downloaded file..." -Diag
                Unblock-File -Path $AgentArchivePath

                $AgentZip = Get-Item -Path $AgentArchivePath
                Write-Message "- Downloaded file size: $($AgentZip.Length) bytes" -Diag

                $DownloadCompleted = $true
            }
            else
            {
                throw "File not found after download: $AgentArchivePath"
            }
        }
        catch
        {
            Write-Message "Failed download attempt $Attempt of $MaxAttempts from: $($AgentSource) ($($_.Exception.Message))" -Warning
            Write-Message "- Exception: $($_.Exception)" -Diag
            
            # Log inner WebException details to help diagnostics.
            if ($_.Exception -and $_.Exception.InnerException)
            {
                [System.Net.WebException]$WebException = $_.Exception.InnerException -as [System.Net.WebException]
                if ($WebException)
                {
                    Write-Message "- Inner WebException:" -Diag
                    Write-Message "  - HResult   = $($WebException.HResult)" -Diag
                    Write-Message "  - Status    = $($WebException.Status)" -Diag
                    Write-Message "  - Message   = $($WebException.Message)" -Diag
                    [System.Net.HttpWebResponse]$HttpWebResponse = $WebException.Response -as [System.Net.HttpWebResponse]
                    if ($HttpWebResponse)
                    {
                        Write-Message "- WebException Response:" -Diag
                        Write-Message "  - CharacterSet      = $($HttpWebResponse.CharacterSet)" -Diag
                        Write-Message "  - ContentEncoding   = $($HttpWebResponse.ContentEncoding)" -Diag
                        Write-Message "  - ContentLength     = $($HttpWebResponse.ContentLength)" -Diag
                        Write-Message "  - ContentType       = $($HttpWebResponse.ContentType)" -Diag
                        Write-Message "  - IsFromCache       = $($HttpWebResponse.IsFromCache)" -Diag
                        Write-Message "  - LastModified      = $($HttpWebResponse.LastModified)" -Diag
                        Write-Message "  - Method            = $($HttpWebResponse.Method)" -Diag
                        Write-Message "  - ProtocolVersion   = $($HttpWebResponse.ProtocolVersion)" -Diag
                        Write-Message "  - ResponseUri       = $($HttpWebResponse.ResponseUri)" -Diag
                        Write-Message "  - Server            = $($HttpWebResponse.Server)" -Diag
                        Write-Message "  - StatusCode        = $($HttpWebResponse.StatusCode.value__)" -Diag
                        Write-Message "  - StatusDescription = $($HttpWebResponse.StatusDescription)" -Diag
                        Write-Message "  - SupportsHeaders   = $($HttpWebResponse.SupportsHeaders)" -Diag
                        if ($HttpWebResponse.Cookies -and $HttpWebResponse.Cookies.Count -gt 0)
                        {
                            Write-Message "- WebException Response Cookies:" -Diag
                            foreach ($Key in $HttpWebResponse.Cookies)
                            {
                                Write-Verbose "  - $($Key) = $($HttpWebResponse.Cookies.Get($Key))" -Diag
                            }
                        }
                        if ($HttpWebResponse.Headers -and $HttpWebResponse.Headers.Count -gt 0)
                        {
                            Write-Message "- WebException Response Headers:" -Diag
                            foreach ($Key in $HttpWebResponse.Headers)
                            {
                                Write-Message "  - $($Key) = $($HttpWebResponse.Headers.Get($Key))" -Diag
                            }
                        }
                    }
                }
            }
            
            if ($Attempt -lt $MaxAttempts)
            {
                Write-Message "- Next attempt will be made in $RetryWaitSec seconds..." -Diag
                Start-Sleep -Seconds $RetryWaitSec
            }
            else
            {
                throw "Failed all $MaxAttempts attempts to download agent from: $($AgentSource) ($($_.Exception.Message))"
            }
        }
        finally
        {
            $WebClient.Dispose()
            $WebClient = $null
            $Attempt++
        }
    }
}

<#
.SYNOPSIS
    Get the download URL for the latest VSTS Agent for the Windows x64 platform.
#>
function Get-VSTSAgentDownloadURL([string]$ProjectCollection)
{
    $ServerUri = New-Object Uri($ProjectCollection)
    $AgentSourceUri = New-Object Uri($ServerUri, "_apis/distributedtask/packages/agent?platform=win7-x64&`$top=1")
    $AuthorizationHeaders = Get-VSTSRestAuthorization

    $VSTSAgentJsonContainingDownloadUrl = Invoke-RestMethod -Uri $AgentSourceUri -ContentType "application/json" -Headers $AuthorizationHeaders -Method Get
    if ($VSTSAgentJsonContainingDownloadUrl)
    {
        if ($VSTSAgentJsonContainingDownloadUrl.Count -eq 0)
        {
            throw "No VSTS Agent locations returned from REST API: $AgentSourceUri"
        }
    
        if ($VSTSAgentJsonContainingDownloadUrl.Count -gt 1)
        {
            Write-Message "Multiple VSTS Agent locations returned from REST API: $AgentSourceUri. Using first one." -Warn
        }

        $VSTSAgentSource = $VSTSAgentJsonContainingDownloadUrl.value[0]
        Write-Message "- Agent JSON: $($VSTSAgentSource)" -Diag

        if ($VSTSAgentSource.downloadUrl)
        {
            $AgentDownloadUrl = $VSTSAgentSource.downloadUrl
            Write-Message "- Agent download URL: $AgentDownloadUrl"
        }
        else
        {
            throw "No downloadUrl property in VSTS Agent location JSON returned from REST API: $AgentSourceUri"
        }
    }
    else
    {
        throw "Failed to get VSTS Agent location from REST API: $AgentSourceUri"
    }

    return $AgentDownloadUrl
}

<#
.SYNOPSIS
    Expand the VSTS Agent archive.
#>
function Expand-VSTSAgentArchive([string]$AgentArchivePath, [string]$AgentPath)
{
    $VSOAgentConfigPath = Join-Path -Path $AgentPath -ChildPath "config.cmd"

    # Expand archive if the agent executable does not already exist.
    if (!(Test-Path -Path $VSOAgentConfigPath -PathType Leaf -ErrorAction SilentlyContinue))
    {
        if (!(Test-Path -Path $AgentArchivePath -PathType Leaf -ErrorAction SilentlyContinue))
        {
            throw "No VSTS Agent archive found at: $AgentArchivePath"
        }
        
        Write-Message "- VSTS Agent archive: $AgentArchivePath" -Diag

        # Ensure that the archive is unblocked before expanding.
        # In case the archive has been downloaded from an untrusted source.
        Unblock-File -Path $AgentArchivePath

        if (!(Test-Path -Path $AgentPath -ErrorAction SilentlyContinue))
        {
            Write-Message "- Creating destination folder: $AgentPath" -Diag
            New-Item -ItemType Directory -Force -Path $AgentPath | Out-Null
        }

        Write-Message "- Expanding files to: $AgentPath" -Diag
        if ($PSVersionTable.PSVersion.Major -ge 5)
        {
            Expand-Archive -Path $AgentArchivePath -DestinationPath $AgentPath -Force -WarningVariable ExpandWarnings
        }
        else
        {
            Expand-Archive -Path $AgentArchivePath -OutputPath $AgentPath -Force -WarningVariable ExpandWarnings
        }

        if ($ExpandWarnings -and $ExpandWarnings.Count -gt 0)
        {
            Write-Message "- Expanded files with $($ExpandWarnings.Count) warnings:" -Diag
            $ExpandWarnings | % { Write-Message $_ -Diag }
        }
        
        if (Test-Path $VSOAgentConfigPath -PathType Leaf -ErrorAction SilentlyContinue)
        {
            Write-Message "- Expanded VSTS Agent files successfully." -Diag
        }
        else
        {
            throw "No VSTS Agent config.cmd found after expanding archive. Expected file: $VSOAgentConfigPath"
        }
    }
    else
    {
        Write-Message "- VSTS Agent config.cmd already exists. No need to expand VSTS Agent archive." -Diag
    }
}

<#
.SYNOPSIS
    Get the VSTS REST API authorization information for use in request header.
#>
function Get-VSTSRestAuthorization()
{
    $RestLogin = ""

    if ($VSOAccessToken)
    {
        $RestLogin = "PAT:$($VSOAccessToken)"
    }
    else
    {
        throw "No VSTS authentication information has been provided. A Personal Access Token must be provided."
    }

    $BasicAuthBase64 = "Basic $([System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($RestLogin)))"
    $RestAuthorizationHeader = @{Authorization=("$BasicAuthBase64")}

    return $RestAuthorizationHeader
}

<#
.SYNOPSIS
    Get the VSTS Agent login information.
#>
function Get-VSTSAgentLogin([switch]$Scrubbed)
{
    $AgentLogin = ""

    if ($VSOAccessToken)
    {
        if ($Scrubbed)
        {
            $AgentLogin = "$($VSOAccessToken -ireplace ".", "*")"
        }
        else
        {
            $AgentLogin = "$($VSOAccessToken)"
        }
    }
    else
    {
        throw "No VSTS authentication information has been provided. A Personal Access Token must be provided."
    }
    return $AgentLogin
}

<#
.SYNOPSIS
    Remove any existing VSTS Agent service.
#>
function Remove-VSTSAgent([switch]$RemoveFiles, [string]$AgentPath)
{
    if (Test-Path -Path $AgentPath -PathType Container -ErrorAction SilentlyContinue)
    {
        $VSOAgentConfigPath = Join-Path -Path $AgentPath -ChildPath "config.cmd"
        if (Test-Path -Path $VSOAgentConfigPath -PathType Leaf -ErrorAction SilentlyContinue)
        {
            $Login = Get-VSTSAgentLogin
        
            Write-Message "- Removing VSTS Agent..." -Diag
            $VSOAgentOutput = & $VSOAgentConfigPath remove --unattended --auth PAT --token "$Login" 2>&1

            # Check exit code to make sure the service was correctly removed.
            $VSOAgentExitCode = [int]$LASTEXITCODE

            # Log output if any.
            $AgentOutputMessages = @()
            if ($VSOAgentOutput -and $VSOAgentOutput.Count -gt 0)
            {
                Write-Message "- Output:" -Diag
                foreach ($Output in $VSOAgentOutput)
                {
                    $AgentOutputMessage = $null
                    # Output to STDERR will show up as an ErrorRecord rather than simply a string.                  
                    [System.Management.Automation.ErrorRecord]$OutputError = $Output -as [System.Management.Automation.ErrorRecord]
                    if ($OutputError -and $OutputError.Exception)
                    {
                        $AgentOutputMessage = $OutputError.Exception.Message
                    }
                    else
                    {
                        $AgentOutputMessage = $Output
                    }

                    Write-Message "- $($AgentOutputMessage)" -Diag
                    # Don't save empty messages.
                    if ($AgentOutputMessage)
                    {
                        $AgentOutputMessages += $AgentOutputMessage
                    }
                }
            }

            Write-Message "- VSTS Agent removal completed with exit code: $VSOAgentExitCode" -Diag
            if ($VSOAgentExitCode -ne 0)
        {
                $ExceptionMessage = "VSTS Agent removal returned an unexpected exit code: $VSOAgentExitCode"
                if ($AgentOutputMessages.Count -gt 0)
                {
                    $ExceptionMessage += " - Output: $($AgentOutputMessages | Out-String)"
                    $ExceptionMessage = $ExceptionMessage.Trim()
                }
                throw $ExceptionMessage
        }
        }
        else
        {
            Write-Message "- No VSTS Agent executable found at: $VSOAgentExePath. No VSTS Agent to unconfigure." -Diag
        }

        if ($RemoveFiles)
        {
            Write-Message "- Removing VSTS Agent files under: $AgentPath" -Diag
            $Removed = $false
            $Attempt = 1
            $MaxAttempts = 5
            while (!$Removed -and $Attempt -le $MaxAttempts)
            {
                try
                {
                    Remove-Item -Path $AgentPath -Recurse -Force -ErrorAction Stop
                    $Removed = $true
                }
                catch
                {
                    Write-Message "- Unable to remove VSTS Agent files on attempt $($Attempt) of $($MaxAttempts): $($_)" -Warn
                    $Attempt++
                    if ($Attempt -le $MaxAttempts)
                    {
                        Write-Message "- Removing files will be retried in 2 seconds..." -Diag
                        Start-Sleep -Seconds 2
                    }
                }
            }
            Write-Message "- Removing VSTS Agent files complete." -Diag
        }
    }
    else
    {
        Write-Message "- No VSTS Agent path found at: $AgentPath. No VSTS Agent to remove." -Diag
    }
}

<#
.SYNOPSIS
    Setup a new VSTS Agent service.
#>
function Setup-VSTSAgent([string]$AgentPath)
{
    if (Test-Path -Path $AgentPath -PathType Container -ErrorAction SilentlyContinue)
    {
        $VSOAgentConfigPath = Join-Path -Path $AgentPath -ChildPath "config.cmd"

        if (Test-Path -Path $VSOAgentConfigPath -PathType Leaf)
        {
            $Login = Get-VSTSAgentLogin
            $ScrubbedLogin = Get-VSTSAgentLogin -Scrubbed

            Write-Message "- Configuring VSTS Agent..." -Diag
        
            # Make lower case and remove defaultcollection if it exists
            $VSO_ServerURL = $VSO_ProjectCollection.ToLowerInvariant()
            if ($VSO_ServerURL.Contains("/defaultcollection"))
            {
                $VSO_ServerURL = $VSO_ServerURL.TrimEnd("/defaultcollection")
            }

            Write-Message "- VSTS URL: $VSO_ServerURL" -Diag
            Write-Message "- Agent name: $AgentName" -Diag
            Write-Message "- Agent pool name: $AgentPoolName" -Diag
            Write-Message "- Agent service display name: $AgentDisplayName" -Diag
            if ($AgentWorkFolder)
            {
                Write-Message "- Agent work folder: $AgentWorkFolder" -Diag
                Write-Message "$VSOAgentConfigPath --unattended --url `"$VSO_ServerURL`" --agent `"$AgentName`" --pool `"$AgentPoolName`" --auth PAT --token `"$ScrubbedLogin`" --runasservice --replace --windowslogonaccount `"$ServiceAccountName`" --windowslogonpassword `"$($ServiceAccountPassword -ireplace ".", "*")`" --work `"$AgentWorkFolder`"" -Diag
                $VSOAgentOutput = & "$VSOAgentConfigPath" --unattended --url "$VSO_ServerURL" --agent "$AgentName" --pool "$AgentPoolName" --auth PAT --token "$Login" --runasservice --replace --windowslogonaccount "$ServiceAccountName" --windowslogonpassword "$ServiceAccountPassword" --work "$AgentWorkFolder" 2>&1
            }
            else
            {
                Write-Message "$VSOAgentConfigPath --unattended --url `"$VSO_ServerURL`" --agent `"$AgentName`" --pool `"$AgentPoolName`" --auth PAT --token `"$ScrubbedLogin`" --runasservice --replace  --windowslogonaccount `"$ServiceAccountName`" --windowslogonpassword `"$($ServiceAccountPassword -ireplace ".", "*")`"" -Diag
                $VSOAgentOutput = & "$VSOAgentConfigPath" --unattended --url "$VSO_ServerURL" --agent "$AgentName" --pool "$AgentPoolName" --auth PAT --token "$Login" --runasservice --replace --windowslogonaccount "$ServiceAccountName" --windowslogonpassword "$ServiceAccountPassword" 2>&1
            }

            # Check exit code to make sure the service was correctly configured.
            $VSOAgentExitCode = [int]$LASTEXITCODE
                
            # Log output if any.
            $AgentOutputMessages = @()
            if ($VSOAgentOutput -and $VSOAgentOutput.Count -gt 0)
            {
                Write-Message "- Output:" -Diag
                foreach ($Output in $VSOAgentOutput)
                {
                    $AgentOutputMessage = $null
                    # Output to STDERR will show up as an ErrorRecord rather than simply a string.                  
                    [System.Management.Automation.ErrorRecord]$OutputError = $Output -as [System.Management.Automation.ErrorRecord]
                    if ($OutputError -and $OutputError.Exception)
                    {
                        $AgentOutputMessage = $OutputError.Exception.Message
                    }
                    else
                    {
                        $AgentOutputMessage = $Output
                    }

                    Write-Message "- $($AgentOutputMessage)" -Diag
                    # Don't save empty messages.
                    if ($AgentOutputMessage)
                    {
                        $AgentOutputMessages += $AgentOutputMessage
                    }
                }
            }

            Write-Message "- VSTS Agent configuration completed with exit code: $VSOAgentExitCode" -Diag
            if ($VSOAgentExitCode -ne 0)
            {
                $ExceptionMessage = "VSTS Agent configuration returned an unexpected exit code: $VSOAgentExitCode"
                if ($AgentOutputMessages.Count -gt 0)
                {
                    $ExceptionMessage += " - Output: $($AgentOutputMessages | Out-String)"
                    $ExceptionMessage = $ExceptionMessage.Trim()
                }
                throw $ExceptionMessage
            }
        }
        else
        {
            throw "No VSTS Agent config.cmd found at: $VSOAgentConfigPath"
        }
    }
    else
    {
        throw "No VSTS Agent path found at: $AgentPath"
    }
}


[int]$ExitCode = 0
try
{
    Write-Message "Configuring VSTS Agent service: $AgentName"

    [string]$AgentArchivePath = Join-Path -Path $DynamicsSdkPath -ChildPath "Agent.zip"
    [string]$AgentPath = Join-Path -Path $DynamicsSdkPath -ChildPath "VSOAgent"

    if ($RemoveOnly)
    {
        Write-Message "Removing VSTS Agent service and files..."
        Remove-VSTSAgent -AgentPath $AgentPath -RemoveFiles
    }
    else
    {
        Write-Message "Setting environment variables..."
        Set-AX7SdkEnvironmentVariables -DynamicsSDK $DynamicsSdkPath
    
        Write-Message "Setting registry keys..."
        Set-AX7SdkRegistryValues -DynamicsSDK $DynamicsSdkPath -TeamFoundationServerUrl $VSO_ProjectCollection -AosWebsiteName $AosWebsiteName

        if ($Force)
        {
            Write-Message "Removing VSTS Agent service and files..."
            Remove-VSTSAgent -AgentPath $AgentPath -RemoveFiles
        }
        else
        {
            Write-Message "Removing existing VSTS Agent service..."
            Remove-VSTSAgent -AgentPath $AgentPath
        }
     
        Write-Message "Downloading VSTS Agent archive..."
        Download-VSTSAgent -ProjectCollection $VSO_ProjectCollection -AgentArchivePath $AgentArchivePath -Force:$Force
        
        Write-Message "Expanding VSTS Agent archive..."
        Expand-VSTSAgentArchive -AgentArchivePath $AgentArchivePath -AgentPath $AgentPath
   
        Write-Message "Configuring new VSTS Agent service..."
        Setup-VSTSAgent -AgentPath $AgentPath
    }

    Write-Message "Configuring VSTS Agent service complete."
}
catch [System.Exception]
{
    Write-Message "- Exception thrown at $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())$([Environment]::NewLine)$($_.Exception.ToString())" -Diag
    Write-Message "Error configuring VSTS Agent service: $($_)" -Error
    if ($ThrowOnError)
    {
        Write-Message "- Throwing exception on error for parent to handle." -Diag
        throw
    }
    else
    {
        $ExitCode = -1
    }
}
Write-Message "Script completed with exit code: $ExitCode"
Exit $ExitCode
# SIG # Begin signature block
# MIIjngYJKoZIhvcNAQcCoIIjjzCCI4sCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBTGWSwpq3gaYGX
# DDCccDezKLkxicYjk5MXwvXDVX+bdaCCDYEwggX/MIID56ADAgECAhMzAAAB32vw
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
# RcBCyZt2WwqASGv9eZ/BvW1taslScxMNelDNMYIVczCCFW8CAQEwgZUwfjELMAkG
# A1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQx
# HjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9z
# b2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAxMQITMwAAAd9r8C6Sp0q00AAAAAAB3zAN
# BglghkgBZQMEAgEFAKCBrjAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgor
# BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgu4Bd2fFh
# SkUMuN8gTt2VOlaiT0eCWkFuA81eHgpuA+swQgYKKwYBBAGCNwIBDDE0MDKgFIAS
# AE0AaQBjAHIAbwBzAG8AZgB0oRqAGGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbTAN
# BgkqhkiG9w0BAQEFAASCAQADYmOhsr3duyS0eUVjOsLO0x+8an6I5V1e9jXMb9Do
# 2pHKev5rzlxhFIoeItx+NQSvmQGC4Z5wgO51gyJPVNtmiiNVQx9hlSCuGV37OJxp
# aHJome/36+ozWkubTN+izyO2Wq0WlNhwigsYGnAB7C4MPqj3Q0j0MuLmUF2eHPxD
# wtuAs1rtL1cQ7JeWW331W7ZFb0v/9xGN8ypWwMohhEZsSY+l3EblVK0q55WA7F+a
# szzHX/oJxfsdcu25RiMqKXCzviEFLuNlMYq6WnKlBM11SqAG9znJloArq4pjOTKv
# Z0WdiJrivGZEXWbDT/zS2ZqZYqm6U2UE6NqNSGSvkXAQoYIS/TCCEvkGCisGAQQB
# gjcDAwExghLpMIIS5QYJKoZIhvcNAQcCoIIS1jCCEtICAQMxDzANBglghkgBZQME
# AgEFADCCAVkGCyqGSIb3DQEJEAEEoIIBSASCAUQwggFAAgEBBgorBgEEAYRZCgMB
# MDEwDQYJYIZIAWUDBAIBBQAEIN5Ff0cTRAjtNTy9HqndjtGZIGV7jEUYMg9D/oT7
# 9mgTAgZgPSuf0jQYEzIwMjEwMzAzMDMxMDAwLjc3N1owBIACAfSggdikgdUwgdIx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1p
# Y3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEmMCQGA1UECxMdVGhh
# bGVzIFRTUyBFU046RDA4Mi00QkZELUVFQkExJTAjBgNVBAMTHE1pY3Jvc29mdCBU
# aW1lLVN0YW1wIFNlcnZpY2Wggg5MMIIE+TCCA+GgAwIBAgITMwAAAUGvf1KXXPLc
# RQAAAAABQTANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0Eg
# MjAxMDAeFw0yMDEwMTUxNzI4MjdaFw0yMjAxMTIxNzI4MjdaMIHSMQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQg
# SXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxJjAkBgNVBAsTHVRoYWxlcyBUU1Mg
# RVNOOkQwODItNEJGRC1FRUJBMSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFt
# cCBTZXJ2aWNlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA8irLqL28
# dal+PJUmUJOwvYn/sOCEzQzZyj94XbFPtRhDhPjagvvKOv1GgMoOuXvkpM3uM5E6
# 7vyOCPxqhTAzq7Ak3zkEXXBv7JoM8Xm0x5UcnAkpUiEo0eycRl6bnYIB3KlZW3uz
# 4Jc2v2FV0KCGkLrvqfKP8V/i2hVyN854OejWpx8wGUazM4CYUVowcgEDc76OY+Xa
# 4W27DCZJm2f9ol4BjSL+b2L/T8n/LEGknaUxwSQTN1LQCt+uBDCASd6VQR5CLLJV
# t6MBL0W1NlaWxEAJwlIdyBnS1ihLvRg1jc/KUZe0sRFdD3fhKrjPac3hoy007Fvr
# 6Go0WJ4pr2rJdQIDAQABo4IBGzCCARcwHQYDVR0OBBYEFC0oPyxuLpD9RXBr9c8N
# O0EFEsbEMB8GA1UdIwQYMBaAFNVjOlyKMZDzQ3t8RhvFM2hahW1VMFYGA1UdHwRP
# ME0wS6BJoEeGRWh0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1
# Y3RzL01pY1RpbVN0YVBDQV8yMDEwLTA3LTAxLmNybDBaBggrBgEFBQcBAQROMEww
# SgYIKwYBBQUHMAKGPmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMv
# TWljVGltU3RhUENBXzIwMTAtMDctMDEuY3J0MAwGA1UdEwEB/wQCMAAwEwYDVR0l
# BAwwCgYIKwYBBQUHAwgwDQYJKoZIhvcNAQELBQADggEBAFJ63yJ92ChqCgpexD48
# okviGuC4ikNsvmwlCSet1sFpvJEzLJB8cTF4z4qQTz8AsQtcew6mAVmQCYDu9f5e
# e11xXj1LwHYsZGnSs/OfRul1VKmY51OQpqvK5O/Ct4fs0Iblzo8eyOLJygTk97aX
# VA4Uzq8GblL7LQ5XiwAY446MOALnNXFo/Kq9tvzipwY1YcRn/nlMQ+b92OiLLmHV
# Mi2wAUORiKFvaAfYWjhQd+2qHLMsdpNluwBbWe7FF5ABsDo0HROMWyCgxdLQ3vqr
# 3DMSH3ZWKiirFsvWJmchfZPGRObwqszvSXPFmPBZ9o+er+4UoLV+50GWnnQky7HV
# gLkwggZxMIIEWaADAgECAgphCYEqAAAAAAACMA0GCSqGSIb3DQEBCwUAMIGIMQsw
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
# 2u8JJxzVs341Hgi62jbb01+P3nSISRKhggLWMIICPwIBATCCAQChgdikgdUwgdIx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1p
# Y3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEmMCQGA1UECxMdVGhh
# bGVzIFRTUyBFU046RDA4Mi00QkZELUVFQkExJTAjBgNVBAMTHE1pY3Jvc29mdCBU
# aW1lLVN0YW1wIFNlcnZpY2WiIwoBATAHBgUrDgMCGgMVAKrlvym1CquIoQcrzncL
# vkD1WpUDoIGDMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
# b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwDQYJ
# KoZIhvcNAQEFBQACBQDj6PuAMCIYDzIwMjEwMzAzMDE1OTI4WhgPMjAyMTAzMDQw
# MTU5MjhaMHYwPAYKKwYBBAGEWQoEATEuMCwwCgIFAOPo+4ACAQAwCQIBAAIBBAIB
# /zAHAgEAAgIRSDAKAgUA4+pNAAIBADA2BgorBgEEAYRZCgQCMSgwJjAMBgorBgEE
# AYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0GCSqGSIb3DQEBBQUAA4GB
# AC0G0IlzIF64A98IBBNFcmJwDswQQJJQYBNmwukwLPgA/kG08Oby2yXUI5pzV+La
# XHw1v22MBKjfMOcpsqYsVoFMy1ky3MlWRSJLXu7HDjCAXRe5w5w1Xiry3h7MMK0D
# sIQTO++W83mFhek9RYOu2aDlolVl5gHRdIdrSk34g9MmMYIDDTCCAwkCAQEwgZMw
# fDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMd
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAFBr39Sl1zy3EUAAAAA
# AUEwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRAB
# BDAvBgkqhkiG9w0BCQQxIgQgUUExNJaDnapptbWJsulzsRwiXcfiU1gvMm/VqJRD
# j3MwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCBRPwE8jOpzdJ5wdE8soG1b
# S846dP7vyFpaj5dzFV6t3jCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwAhMzAAABQa9/Updc8txFAAAAAAFBMCIEIDI8k+AZ2+qKrT0TjZ7LmA5G
# C+u5xZScebfL24KQIuXCMA0GCSqGSIb3DQEBCwUABIIBAOH+f4q2wYZ7KLnsJgtE
# V4g3RQSDjtxgCSaGlq9g33+aZNpC4HX17wQNLxj5LElx8yae2fm6fQdpWhTCNRj5
# vlP8+A+4EXy3pRvD2xWYQmnuT4YMzgBbihkLGqGABP3TDo/Q93ilNJ5cYdN+iFz4
# Mm87Ps0Z30lKTLMfVG0ye0B9qpuYZ8QFfRUH9BQdLuaXT6UakzjNNRatT4yrSklU
# ZCYl1KpWva1/b3EDmfFIy84UQ4gydtTGb14t/LkhSLHEXnhhO8wQat5KxpGexmJd
# 3IUhiro8aqnHISgiR6N5GBEhvrhAgypUDn3zEYPWhm0+heyXmxlsRSntAW4HJVOe
# A30=
# SIG # End signature block
