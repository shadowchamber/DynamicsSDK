<#
.SYNOPSIS
    Configure a VSTS Project with a Build Definition to be able to build
    Dynamics AX customizations.

.DESCRIPTION
    This script is intended for use in the Dynamics AX Development setup
    process to configure a project and build definition to be able to build
    Dynamics AX customizations. It will add a build definition and a add
    project file and ReadMe files in the version control system.

.NOTES
    When running through automation, use the -LogPath option to redirect
    output to a log file rather than the console.

    Copyright © 2016 Microsoft. All rights reserved.
#>
[Cmdletbinding()]
Param(
    [Parameter(Mandatory=$true, HelpMessage="The Visual Studio Team Services project collection URL to connect to.")]
    [string]$VSO_ProjectCollection,

    [Parameter(Mandatory=$true, HelpMessage="The Visual Studio Team Services project name where the build process template will be checked in.")]
    [string]$ProjectName,

    [Parameter(Mandatory=$false, HelpMessage="The user name to authenticate to Visual Studio Team Services.")]
    [string]$AlternateUsername,
    
    [Parameter(Mandatory=$false, HelpMessage="The password of the user to authenticate to Visual Studio Team Services.")]
    [string]$AlternatePassword,
    
    [Parameter(Mandatory=$false, HelpMessage="The personal access token to use for authentication to Visual Studio Team Services.")]
    [string]$VSOAccessToken=$null,

    [Parameter(Mandatory=$false, HelpMessage="The build project for Dynamics AX to check in.")]
    [string]$AxModuleProj="AXModulesBuild.proj",
    
    [Parameter(Mandatory=$false, HelpMessage="The branch to create the build definition for.")]
    [string]$Branch = "Main",

    [Parameter(Mandatory=$false, HelpMessage="The name of the build definition to create.")]
    [string]$BuildDefinitionName = "Unified Operations platform - Build $($Branch)",

    [Parameter(Mandatory=$false, HelpMessage="The agent pool name to use for the default queue in the build definition.")]
    [string]$AgentPoolName = "Default",

    [Parameter(Mandatory=$false, HelpMessage="The time zone to use for scheduling daily builds")]
    [string]$BuildScheduleTimeZone = "UTC",

    [Parameter(Mandatory=$false, HelpMessage="Overwrite existing build and release definitions and project files if they already exist in the project.")]
    [switch]$Force,

    [Parameter(Mandatory=$false, HelpMessage="The Dynamics SDK path.")]
    [string]$DynamicsSdkPath="$($env:SystemDrive)\DynamicsSDK",

    [Parameter(Mandatory=$false, HelpMessage="The Dynamics AX AOS website name.")]
    [string]$AosWebsiteName="AosService",
    
    [Parameter(Mandatory=$false, HelpMessage="The full path to the file to write output to (If not specified the output will be written to the host).")]
    [string]$LogPath=$null,

    [Parameter(Mandatory=$false, HelpMessage="Throw an exception if an error occurs rather than returning a non-zero exit code.")]
    [switch]$ThrowOnError,

    [Parameter(Mandatory=$false, HelpMessage="Create the release definition.")]
    [switch]$CreateReleaseDefinition,

    [Parameter(Mandatory=$false, HelpMessage="The name of the release definition to create.")]
    [string]$ReleaseDefinitionName = "Dynamics 365 for Operations - Release $($Branch)",

    [Parameter(Mandatory=$false, HelpMessage="The name of the release definition environment.")]
    [string]$ReleaseDefinitionEnvironmentName = "Sandbox Test"
)

# Import module for Write-Message and other common functions (Picks up $LogPath variable).
Import-Module $(Join-Path -Path $PSScriptRoot -ChildPath "DynamicsSDKCommon.psm1") -Function "Write-Message", "Set-AX7SdkRegistryValues", "Set-AX7SdkEnvironmentVariables"
# Import module for New-AX7BuildDefinition and other build definition functions.
Import-Module $(Join-Path -Path $PSScriptRoot -ChildPath "CreateBuildDefinition.psm1")
# Import module for New-AX7ReleaseDefinition and other release definition functions.
Import-Module $(Join-Path -Path $PSScriptRoot -ChildPath "CreateReleaseDefinition.psm1")

<#
.SYNOPSIS
    Create a TFS workspace.
#>
function Create-Workspace([Microsoft.TeamFoundation.Client.TfsTeamProjectCollection]$TeamProjectCollection)
{
    Write-Message "- Getting Version Control Server service instance..." -Diag
    $VersionControlServer = $TeamProjectCollection.GetService('Microsoft.TeamFoundation.VersionControl.Client.VersionControlServer')
    if ($VersionControlServer -eq $null)
    {
        throw [System.Exception] "Failed to get Version Control Server service instance."
    }

    Write-Message "- Getting team project: $ProjectName" -Diag
    $TeamProject = $VersionControlServer.TryGetTeamProject($ProjectName)
    if ($TeamProject -eq $null)
    {
        throw [System.Exception] "Failed to get team project from name: $($ProjectName)"
    }
    Write-Message "- Found team project: $($TeamProject.Name)" -Diag

    Write-Message "- Creating new work space..." -Diag
    $Random = New-Object System.Random
    do
    {
        $WorkspaceName = "$($Env:COMPUTERNAME)_Temp_$($Random.Next())"
    }
    While ($VersionControlServer.QueryWorkspaces($WorkspaceName, $null, $null) -contains $WorkspaceName)

    $WorkspaceParameters = New-Object Microsoft.TeamFoundation.VersionControl.Client.CreateWorkspaceParameters($WorkspaceName)
    $WorkspaceParameters.Location = [Microsoft.TeamFoundation.VersionControl.Common.WorkspaceLocation]::Local
    $WorkspaceParameters.Comment = "Temporary workspace for automated check-in."
    $Workspace = $VersionControlServer.CreateWorkspace($WorkspaceParameters)

    return $Workspace
}

<#
.SYNOPSIS
    Check in file to TFS.
#>
function Checkin-File([string]$Path, [string]$FileName, [string]$ServerMappingPath, [Microsoft.TeamFoundation.VersionControl.Client.Workspace]$Workspace, [switch]$Force)
{
    $WorkspaceLocation = Join-Path -Path ($env:TEMP) -ChildPath $($Workspace.Name)
    
    try
    {
        # Note: Test-Path can write an access denied error with the default error
        # action which is distracting. Silence it.
        if (!(Test-Path -Path $WorkspaceLocation -ErrorAction SilentlyContinue))
        {
            $Directory = New-Item -ItemType Directory $WorkspaceLocation -Force
        }

        # Map workspace location.
        Write-Message "- Mapping $ServerMappingPath to: $WorkspaceLocation" -Diag
        $Workspace.Map($ServerMappingPath, $WorkspaceLocation)
        $Source = (Join-Path -Path $Path -ChildPath $FileName)
        $Destination = (Join-Path -Path $WorkspaceLocation -ChildPath $FileName)

        # Check if file is already checked in.
        $ServerItem = $Workspace.GetServerItemForLocalItem($Destination)
        $ItemsAdded = 0
        if ($ServerItem -ne $null -and $Workspace.VersionControlServer.ServerItemExists($ServerItem, [Microsoft.TeamFoundation.VersionControl.Client.ItemType]::Any))
        {
            Write-Message "- Existing file found on server: $ServerItem" -Diag
            if ($Force)
            {
                Write-Message "- Getting latest version of existing file..." -Diag
                $GetStatus = $Workspace.Get($ServerItem, [Microsoft.TeamFoundation.VersionControl.Client.VersionSpec]::Latest, [Microsoft.TeamFoundation.VersionControl.Client.RecursionType]::None, [Microsoft.TeamFoundation.VersionControl.Client.GetOptions]::Overwrite)
                $ExistingHash = Get-FileHash -Path $Destination -Algorithm MD5
                Write-Message "- Existing file MD5 hash: $($ExistingHash.Hash)" -Diag
                $NewHash = Get-FileHash -Path $Source -Algorithm MD5
                Write-Message "- New file MD5 hash: $($NewHash.Hash)" -Diag
                if ($NewHash.Hash -ine $ExistingHash.Hash)
                {
                    Write-Message "- Adding edit of existing file to pending changes: $FileName" -Diag
                    $ItemsAdded = $Workspace.PendEdit($ServerItem, [Microsoft.TeamFoundation.VersionControl.Client.RecursionType]::None)
                    Write-Message "- Updating existing file..." -Diag
                    Copy-Item -Path $Source -Destination $Destination -Force
                }
                else
                {
                    Write-Message "- MD5 hash values are identical. No need to update file: $FileName" -Diag
                }
            }
            else
            {
                Write-Message "- No update will be made to existing file (Force: $($Force))." -Diag
            }
        }
        else
        {
            Write-Message "- No existing file found on server." -Diag
            Copy-Item -Path $Source -Destination $Destination -Force
            Write-Message "- Adding file to pending changes: $FileName" -Diag
            $ItemsAdded = $Workspace.PendAdd($Destination)
        }

        if ($ItemsAdded -gt 0)
        {
            Write-Message "- Getting pending changes..." -Diag
            $PendingChanges = $Workspace.GetPendingChanges()
            if ($PendingChanges -ne $null)
            {
                # Check-in pending changes.
                Write-Message "- Checking in pending changes..." -Diag
                $Success = $Workspace.CheckIn($PendingChanges, "Automated check-in for $($FileName) from $($Path).")
                if (!$Success)
                {
                    throw [System.Exception] "Failed to check in pending changes."
                }
            }
            else
            {
                Write-Message "- No pending changes requires check-in." -Diag
            }
            Write-Message "- Check-in complete." -Diag
        }
        else
        {
            Write-Message "- There are no files that needs to be checked in." -Diag
        }
    }
    finally
    {
        # Note: Test-Path can write an access denied error with the default error
        # action which is distracting. Silence it.
        if ($WorkspaceLocation -and (Test-Path -Path $WorkspaceLocation -ErrorAction SilentlyContinue))
        {
            Remove-Item -Path $WorkspaceLocation -Recurse -Force
        }
    }
}

<#
.SYNOPSIS
    Remove a TFS workspace.
#>
function Remove-Workspace([Microsoft.TeamFoundation.VersionControl.Client.Workspace]$Workspace)
{
    if ($Workspace -ne $null)
    {
        $WorkspaceName = $Workspace.Name
        $LocalFolders = @($Workspace.Folders | Select-Object -ExpandProperty LocalItem)
        Write-Message "- Deleting workspace: $WorkspaceName" -Diag
        $Deleted = $Workspace.Delete()
        if ($Deleted)
        {
            foreach ($Folder in $LocalFolders)
            {
                # Note: Test-Path can write an access denied error with the default error
                # action which is distracting. Silence it.
                if ($Folder -and (Test-Path -Path $Folder -ErrorAction SilentlyContinue))
                {
                    Write-Message "- Deleting workspace folder: $Folder" -Diag
                    Remove-Item -Path $Folder -Force -Recurse
                }
            }
        }
        else
        {
            Write-Message "- Failed to delete workspace: $WorkspaceName" -Diag
        }
    }
}

<#
.SYNOPSIS
    Load types from the specified assembly.
#>
function Load-Assembly([string]$Path, [string]$FileName, [switch]$LoadDetails)
{
    if ($LoadDetails)
    {
        $AssembliesBefore = @([AppDomain]::CurrentDomain.GetAssemblies() | Sort-Object -Property FullName)
    }
    
    $AssemblyFilePath = Join-Path -Path $Path -ChildPath $FileName
    Write-Message "- Loading $($AssemblyFilePath)..." -Diag
    Add-Type -Path $AssemblyFilePath
    
    if ($LoadDetails)
    {
        $AssembliesAfter = @([AppDomain]::CurrentDomain.GetAssemblies() | Sort-Object -Property FullName)
        $AssembliesAdded = @(Compare-Object -ReferenceObject $AssembliesBefore -DifferenceObject $AssembliesAfter | Select-Object -ExpandProperty InputObject)
        if ($AssembliesAdded -and $AssembliesAdded.Count -gt 0)
        {
            Write-Message "- New assemblies loaded ($($AssembliesAdded.Count)):" -Diag
            foreach ($Assembly in $AssembliesAdded)
            {
                Write-Message "  $($Assembly.FullName): $($Assembly.Location)" -Diag
            }
        }
        else
        {
            Write-Message "- No new assemblies loaded." -Diag
        }
    }
}

<#
.SYNOPSIS
    Finds exisiting or creates a new build definition.
#>
function FindOrCreate-BuildDefinition()
{
    Write-Message "Checking for existing build definition..."
    $BuildDefinition = $null
    $BuildDefinitions = Get-AX7BuildDefinition -VSO_ProjectCollection $VSO_ProjectCollection -ProjectName $ProjectName -AlternateUsername $AlternateUsername -AlternatePassword $AlternatePassword -VSOAccessToken $VSOAccessToken -BuildDefinitionName $BuildDefinitionName
    if ($BuildDefinitions.Count -gt 0 -and $BuildDefinitions[0].value.name -ieq $BuildDefinitionName)
    {
        $BuildDefinitionId = $BuildDefinitions[0].value.id
        Write-Message "Build definition already exists with ID: $BuildDefinitionId"

        if ($Force)
        {
            Write-Message "Removing existing build definition..."
            Remove-AX7BuildDefinition -VSO_ProjectCollection $VSO_ProjectCollection -ProjectName $ProjectName -AlternateUsername $AlternateUsername -AlternatePassword $AlternatePassword -VSOAccessToken $VSOAccessToken -BuildDefinitionId $BuildDefinitionId
        }
        else
        {
            $BuildDefinition = $BuildDefinitions[0].value
        }
    }

    if ($BuildDefinition -eq $null)
    {
        if (!$AgentPoolName)
        {
            $AgentPoolName = "Default"
        }

        # Lookup agent pool by name.
        Write-Message "Getting agent queue that uses the agent pool : $AgentPoolName"
        $AgentQueue = Get-AX7AgentPoolQueue -VSO_ProjectCollection $VSO_ProjectCollection -ProjectName $ProjectName -AlternateUsername $AlternateUsername -AlternatePassword $AlternatePassword -VSOAccessToken $VSOAccessToken -AgentPoolName $AgentPoolName
        
        if ($AgentQueue -ne $null)
        {
            Write-Message "Found agent queue with ID: $($AgentQueue.id)"
        }
        else
        {
            throw "No agent queue could be found that uses agent pool: $AgentPoolName"
        }
        
        # Create the build definition and upload to the project (function exists in CreateBuildDefinition.psm1)
        Write-Message "Creating new build definition..."
        $BuildDefinition = New-AX7BuildDefinition -VSO_ProjectCollection $VSO_ProjectCollection -ProjectName $ProjectName -AlternateUsername $AlternateUsername -AlternatePassword $AlternatePassword -VSOAccessToken $VSOAccessToken -BuildDefinitionName $BuildDefinitionName -Branch $Branch -AgentQueueId $($AgentQueue.id) -BuildScheduleTimeZone $BuildScheduleTimeZone
        if ($BuildDefinition -ne $null -and $BuildDefinition.Name -ieq $BuildDefinitionName)
        {
            Write-Message "Created build definition: $($BuildDefinition.Name) (ID: $($BuildDefinition.Id))"
        }
        else
        {
            $BuildDefinition | Write-Message -Diag
            throw "Failed to create build definition for project name: $ProjectName"
        }
    }

    return $BuildDefinition
}


<#
.SYNOPSIS
    Finds exisiting or creates a new release definition.
#>
function FindOrCreate-ReleaseDefinition
{
    [Cmdletbinding()]
    Param(
        [Parameter(Mandatory=$true, HelpMessage="The build definition json representation.")]
        $BuildDefinition
    )

    # Change the passed in url from https://<account-name>.visualstudio.com/ to https://<account-name>.vsrm.visualstudio.com/
    $restUri = New-Object System.UriBuilder($VSO_ProjectCollection);
    $uriTokens = New-Object System.Collections.ArrayList(, $restUri.Host.Split('.'))
    $uriTokens.Insert(1, "vsrm");
    $restUri.Host =  $uriTokens -join '.'

    Write-Message "Checking for existing release definition..."
    $ReleaseDefinition = Get-AX7ReleaseDefinition -VSO_ProjectCollection $restUri.Uri -ProjectName $ProjectName -AlternateUsername $AlternateUsername -AlternatePassword $AlternatePassword -VSTSAccessToken $VSOAccessToken -ReleaseDefinitionName $ReleaseDefinitionName
    if ($ReleaseDefinition)
    {
        Write-Message "Release definition already exists with ID: $($ReleaseDefinition.Id)"

        if ($Force)
        {
            Write-Message "Removing existing release definition..."
            Remove-AX7ReleaseDefinition -VSO_ProjectCollection $restUri.Uri -ProjectName $ProjectName -AlternateUsername $AlternateUsername -AlternatePassword $AlternatePassword -VSTSAccessToken $VSOAccessToken -ReleaseDefinitionId $ReleaseDefinition.id
            $ReleaseDefinition = $null
        }
    }

    if ($ReleaseDefinition -eq $null)
    {
        # Create the release definition and upload to the project (function exists in CreateReleaseDefinition.psm1)
        Write-Message "Creating new release definition..."
        $ReleaseDefinition = New-AX7ReleaseDefinition -VSO_ProjectCollection $restUri.Uri -ProjectName $ProjectName -AlternateUsername $AlternateUsername -AlternatePassword $AlternatePassword -VSTSAccessToken $VSOAccessToken -ReleaseDefinitionName $ReleaseDefinitionName -ReleaseDefinitionEnvironmentName $ReleaseDefinitionEnvironmentName -BuildDefinition $BuildDefinition
        if ($ReleaseDefinition -ne $null -and $ReleaseDefinition.Name -ieq $ReleaseDefinitionName)
        {
            Write-Message "Created release definition: $($ReleaseDefinition.Name) (ID: $($ReleaseDefinition.Id))"
            if ($DynamicsSdkPath -and (Test-Path -Path $DynamicsSdkPath -ErrorAction SilentlyContinue))
            {
                $InstrumentationScript = Join-Path -Path $DynamicsSdkPath -ChildPath "DevALMInstrumentor.ps1"
                & $InstrumentationScript -CreateReleaseDefinitionMarker
            }
            else
            {
                Write-Message "No release definition creation event was logged as the Dynamics SDK path could not be found at: $DynamicsSdkPath"
            }
        }
        else
        {
            $ReleaseDefinition | Write-Message -Diag
            throw "Failed to create release definition for project name: $ProjectName"
        }
    }

    return $ReleaseDefinition
}
[int]$ExitCode = 0
try
{
    Write-Message "Configuring VSTS build environment..."

    # Make lower case and append defaultcollection if not specified.
    $VSO_ProjectCollection = $VSO_ProjectCollection.ToLowerInvariant()
    if (!($VSO_ProjectCollection.Contains("/defaultcollection")))
    {
        $VSO_ProjectCollection = $VSO_ProjectCollection.TrimEnd("/")
        $VSO_ProjectCollection = "$($VSO_ProjectCollection)/defaultcollection"
    }
    
    Write-Message "- VSTS project collection : $VSO_ProjectCollection"
    Write-Message "- VSTS project name       : $ProjectName"

    Write-Message "Setting environment variables..."
    Set-AX7SdkEnvironmentVariables -DynamicsSDK $DynamicsSdkPath
    
    Write-Message "Setting registry keys..."
    Set-AX7SdkRegistryValues -DynamicsSDK $DynamicsSdkPath -TeamFoundationServerUrl $VSO_ProjectCollection -AosWebsiteName $AosWebsiteName

    # Add types required for working with the version control system.
    Write-Message "Loading required assemblies..."
    $AssemblyPath = Join-Path -Path $DynamicsSdkPath -ChildPath "VSOAgent\externals\vstsom"
    
    # Loading these assemblies may load other assemblies from the same path. LoadDetails will show it.
    Load-Assembly -Path $AssemblyPath -FileName "Microsoft.TeamFoundation.Common.dll" -LoadDetails
    Load-Assembly -Path $AssemblyPath -FileName "Microsoft.TeamFoundation.Client.dll" -LoadDetails
    Load-Assembly -Path $AssemblyPath -FileName "Microsoft.TeamFoundation.WorkItemTracking.Common.dll" -LoadDetails
    Load-Assembly -Path $AssemblyPath -FileName "Microsoft.TeamFoundation.WorkItemTracking.Client.dll" -LoadDetails
    Load-Assembly -Path $AssemblyPath -FileName "Microsoft.TeamFoundation.VersionControl.Common.dll" -LoadDetails
    Load-Assembly -Path $AssemblyPath -FileName "Microsoft.TeamFoundation.VersionControl.Client.dll" -LoadDetails
        
    # Get the login to use for the VSTS Agent.
    Write-Message "Authenticating with VSTS..."
    $tfsCred = $null
    $VSOLogin = ""
    if ($VSOAccessToken)
    {
        # Leverage Personal Access Token for TFSClientCredentials.
        Write-Message "- Authenticating using Personal Access Token." -Diag
        $nc = New-Object System.Net.NetworkCredential("PAT", $VSOAccessToken)
        $bc = New-Object Microsoft.TeamFoundation.Client.BasicAuthCredential($nc)
        $tfsCred = New-Object Microsoft.TeamFoundation.Client.TfsClientCredentials($bc)
        $tfsCred.AllowInteractive = $false
    }
    elseif ($AlternateUsername -and $AlternatePassword)
    {
        # Leverage Alternate Credentials for TFSClientCredentials.
        Write-Message "- Authenticating using alternate user name: $AlternateUsername" -Diag
        $nc = New-Object System.Net.NetworkCredential($AlternateUsername, $AlternatePassword)
        $bc = New-Object Microsoft.TeamFoundation.Client.BasicAuthCredential($nc)
        $tfsCred = New-Object Microsoft.TeamFoundation.Client.TfsClientCredentials($bc)
        $tfsCred.AllowInteractive = $false
    }
    else
    {
        throw "No VSTS authentication information has been provided."
    }
    
    # Ensure VSTS Authentication
    $tfsUri= New-Object System.Uri "$VSO_ProjectCollection"
    $tpc = New-Object Microsoft.TeamFoundation.Client.TfsTeamProjectCollection($tfsUri, $tfsCred)
    $tpc.Authenticate()

    # Create workspace.
    Write-Message "Creating local workspace..."
    $Workspace = Create-Workspace -TeamProjectCollection $tpc
    
    # Check-in AXModulesBuild.proj.
    Write-Message "Checking in build project for Dynamics AX Modules..."
    Write-Message "- Build project: $AxModuleProj" -Diag
    Write-Message "- Branch: $Branch" -Diag
    $ServerMapping = "$/$($ProjectName)/Trunk/$($Branch)"
    Checkin-File -Path $DynamicsSdkPath -FileName $AxModuleProj -ServerMappingPath $ServerMapping -Workspace $Workspace -Force:$Force

    # Check-in Readme.txt for metadata.
    Write-Message "Checking in Readme.txt for metadata..."
    $ServerMapping = "$/$($ProjectName)/Trunk/$($Branch)/Metadata"
    Checkin-File -Path "$DynamicsSdkPath\Metadata" -FileName "Readme.txt" -ServerMappingPath $ServerMapping -Workspace $Workspace -Force:$Force
    
    # Check-in Readme.txt for projects.
    Write-Message "Checking in Readme.txt for projects..."
    $ServerMapping = "$/$($ProjectName)/Trunk/$($Branch)/Projects"
    Checkin-File -Path "$DynamicsSdkPath\Projects" -FileName "Readme.txt" -ServerMappingPath $ServerMapping -Workspace $Workspace -Force:$Force

    # Find exisiting or create a new build build definition
    Write-Message "Trying to find or create new build definition.."
    $BuildDefinition = FindOrCreate-BuildDefinition

    # Find exisiting or create a new release definition
    if ($CreateReleaseDefinition)
    {
        Write-Message "Trying to find or create new release definition.."
        $ReleaseDefinition = FindOrCreate-ReleaseDefinition -BuildDefinition $BuildDefinition
    }

    Write-Message "Configuring VSTS build environment complete."
}
catch [System.Exception]
{
    Write-Message "- Exception thrown at $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())$([Environment]::NewLine)$($_.Exception.ToString())" -Diag
    # If there were exceptions from loading assemblies, log details.
    if ($_.Exception.LoaderExceptions -and $_.Exception.LoaderExceptions.Count -gt 0)
    {
        Write-Message "- LoaderExceptions ($($_.Exception.LoaderExceptions.Count)):" -Diag
        foreach ($Exception in $_.Exception.LoaderExceptions)
        {
            Write-Message "  $($Exception.GetType().FullName): $($Exception.Message)" -Diag
        }
        $AssembliesLoaded = @([AppDomain]::CurrentDomain.GetAssemblies() | Sort-Object -Property FullName)
        if ($AssembliesLoaded -and $AssembliesLoaded.Count -gt 0)
        {
            Write-Message "- Assemblies loaded ($($AssembliesLoaded.Count)):" -Diag
            foreach ($Assembly in $AssembliesLoaded)
            {
                Write-Message "  $($Assembly.FullName): $($Assembly.Location)" -Diag
            }
        }
    }
    Write-Message "Error configuring VSTS build environment: $($_)" -Error
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
finally
{
    Remove-Workspace -Workspace $Workspace
}
Write-Message "Script completed with exit code: $ExitCode"
Exit $ExitCode
# SIG # Begin signature block
# MIIjnAYJKoZIhvcNAQcCoIIjjTCCI4kCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAG3w26pZx9bG39
# /UUQ1rSkdj9aYhZcWyMXHHGmkKIRtqCCDYEwggX/MIID56ADAgECAhMzAAAB32vw
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
# RcBCyZt2WwqASGv9eZ/BvW1taslScxMNelDNMYIVcTCCFW0CAQEwgZUwfjELMAkG
# A1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQx
# HjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9z
# b2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAxMQITMwAAAd9r8C6Sp0q00AAAAAAB3zAN
# BglghkgBZQMEAgEFAKCBrjAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgor
# BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgfMK32dhY
# VYH2Qd7bkoZXCWItHBc4eLgBY7Rm8oy55WgwQgYKKwYBBAGCNwIBDDE0MDKgFIAS
# AE0AaQBjAHIAbwBzAG8AZgB0oRqAGGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbTAN
# BgkqhkiG9w0BAQEFAASCAQBoxbTN5VxDMAyUMrH6NFCJmSgqrT/1CVfyslGPLQg0
# 6fyuBCzEzlZENAPqrBySYZKeaAUtuhdDf5IlISQdIGZki7Di5i1t3BlBWSFNkv3X
# 9drcAcnSoeEYnHYO6U8c2WxvBidqfrbfsE3XQ4uRu4YyKRP/u+OhXhnh+Kyc+xc3
# lDOa+Forenmsgoo2BqcdZaAi3XoO5fgupf8AFSfS7DeOW/e9Dw+iFRTH1Pe4Xk+G
# XAoqFW8SNRRWGryzmjbhb0NrWFC4uguC0wXw5oa9jq0uQxtA+xfKYYsWyzbssW4Y
# 4V7UZF2sB4M4zr37DQXR6eIuUeq0cEfXnvvAWfQXzhvVoYIS+zCCEvcGCisGAQQB
# gjcDAwExghLnMIIS4wYJKoZIhvcNAQcCoIIS1DCCEtACAQMxDzANBglghkgBZQME
# AgEFADCCAVkGCyqGSIb3DQEJEAEEoIIBSASCAUQwggFAAgEBBgorBgEEAYRZCgMB
# MDEwDQYJYIZIAWUDBAIBBQAEIFeYMmbqvYduvN4j2T5vcxu0BELn9NXqep9rkBm3
# sJOFAgZgPQYO22gYEzIwMjEwMzAzMDMwOTU4LjE2M1owBIACAfSggdikgdUwgdIx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1p
# Y3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEmMCQGA1UECxMdVGhh
# bGVzIFRTUyBFU046ODZERi00QkJDLTkzMzUxJTAjBgNVBAMTHE1pY3Jvc29mdCBU
# aW1lLVN0YW1wIFNlcnZpY2Wggg5KMIIE+TCCA+GgAwIBAgITMwAAAT7OyndSxfc0
# KwAAAAABPjANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0Eg
# MjAxMDAeFw0yMDEwMTUxNzI4MjVaFw0yMjAxMTIxNzI4MjVaMIHSMQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQg
# SXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxJjAkBgNVBAsTHVRoYWxlcyBUU1Mg
# RVNOOjg2REYtNEJCQy05MzM1MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFt
# cCBTZXJ2aWNlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAvFTEyDzZ
# fpws404gSC0kt4VSyX/vaxwOfri89gQdxvfQNvvQARebKR3plqHz0ZHZW+bmFxyG
# tTh9zw20LSdpMcWYDFc1rzPuJvTNAnDkKyQP+TqrW7j/lDlCLbqi8ubo4EqSpkHr
# a0Zt15j2r/IJGZbu3QaRY6qYMZxxkkw4Y5ubAwV3E1p+TNzFg8nzgJ9kwEM4xvZA
# f9NhHhM2K/jx092xmKxyFfp0X0tboY9d1OyhdCXl8spOigE32g8zH12Y2NXTfI41
# 41LQU+9dKOKQ7YFF1kwofuGGwxMU0CsDimODWgr6VFVcNDd2tQbGubgdfLBGEBfj
# e0PyoOOXEO1m4QIDAQABo4IBGzCCARcwHQYDVR0OBBYEFJNa8534u9BiLWvwtbZU
# DraGiP17MB8GA1UdIwQYMBaAFNVjOlyKMZDzQ3t8RhvFM2hahW1VMFYGA1UdHwRP
# ME0wS6BJoEeGRWh0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1
# Y3RzL01pY1RpbVN0YVBDQV8yMDEwLTA3LTAxLmNybDBaBggrBgEFBQcBAQROMEww
# SgYIKwYBBQUHMAKGPmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMv
# TWljVGltU3RhUENBXzIwMTAtMDctMDEuY3J0MAwGA1UdEwEB/wQCMAAwEwYDVR0l
# BAwwCgYIKwYBBQUHAwgwDQYJKoZIhvcNAQELBQADggEBAKaz+RF9Wp+GkrkVj6cY
# 5djCdVepJFyufABJ1qKlCWXhOoYAcB7w7ZxzRC4Z2iY4bc9QU93sa2YDwhQwFPeq
# fKZfWSkmrcus49QB9EGPc9FwIgfBQK2AJthaYEysTawS40f6yc6w/ybotAclqFAr
# +BPDt0zGZoExvGc8ZpVAZpvSyXbzGLuKtm8K+R73VC4DUp4sRFck1Cx8ILvYdYSN
# YqORyh0Gwi3v4HWmw6HutafFOdFjaKQEcSsn0SNLfY25qOqnu6DL+NAo7z3qD0eB
# DISilWob5dllDcONfsu99UEtOnrbdl292yGNIyxilpI8XGNgGcZxKN6VqLBxAuKl
# WOYwggZxMIIEWaADAgECAgphCYEqAAAAAAACMA0GCSqGSIb3DQEBCwUAMIGIMQsw
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
# 2u8JJxzVs341Hgi62jbb01+P3nSISRKhggLUMIICPQIBATCCAQChgdikgdUwgdIx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1p
# Y3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEmMCQGA1UECxMdVGhh
# bGVzIFRTUyBFU046ODZERi00QkJDLTkzMzUxJTAjBgNVBAMTHE1pY3Jvc29mdCBU
# aW1lLVN0YW1wIFNlcnZpY2WiIwoBATAHBgUrDgMCGgMVAKBMFej0xjCTjCk1sTdT
# Ka+TzJDUoIGDMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
# b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwDQYJ
# KoZIhvcNAQEFBQACBQDj6NXuMCIYDzIwMjEwMzAyMjMxOTEwWhgPMjAyMTAzMDMy
# MzE5MTBaMHQwOgYKKwYBBAGEWQoEATEsMCowCgIFAOPo1e4CAQAwBwIBAAICDmgw
# BwIBAAICEd0wCgIFAOPqJ24CAQAwNgYKKwYBBAGEWQoEAjEoMCYwDAYKKwYBBAGE
# WQoDAqAKMAgCAQACAwehIKEKMAgCAQACAwGGoDANBgkqhkiG9w0BAQUFAAOBgQAS
# VWTocGt6H6QL177P2cIystEHilXldR8m++eNeNnzIkjha/DhAn6GEjxdK/H5/+zu
# LMMMjBEjNkpLwqYPhlscApGpApQMjTArqD9KuAJVbp5Q542s3ThpCy+n6R/Ji1FK
# LmWYnJKS27/WFZudCNNVrb1cyJbwHjV0gEOFjigk0jGCAw0wggMJAgEBMIGTMHwx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1p
# Y3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAABPs7Kd1LF9zQrAAAAAAE+
# MA0GCWCGSAFlAwQCAQUAoIIBSjAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQw
# LwYJKoZIhvcNAQkEMSIEIL+uvyPQLKMlrzgDcuK3HTmIeCHb9AV3jL3l3Dhi9rvc
# MIH6BgsqhkiG9w0BCRACLzGB6jCB5zCB5DCBvQQgi+vOjaqNTvKOZGut49HXrqtw
# Uj2ZCnVOurBwfgQxmxMwgZgwgYCkfjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0Eg
# MjAxMAITMwAAAT7OyndSxfc0KwAAAAABPjAiBCChpDX9KcSu9+QcwFp6NltYmc7U
# 6h6t2X9Yrm71JhU+AjANBgkqhkiG9w0BAQsFAASCAQBw/vDaYEQ9kFaOmf/LO/Ql
# Eqtvo/0lnU07hSURe18cYG5OVgt995zAcfXFaLJt3IqzfXX3QBrvd39W6RwhAHq3
# 4p7tz4sBpfRi68wzT3ZxxJ40GXzolGCL8x6xvFlQTXgIJA0VVTlsnEesWHoWyEXn
# UlXrmqkDKB3it3cD7AhnzfFclSiPld9xvMhfZ2yso9/mIEC2Qxh49BFJY5i1TiQw
# kw6GH+8sWOw5TMMBWKf2Cl/9ty5hyojs6TKXUUzw9XgqpGcvewOQZ5WsE+FX/lxm
# M1gAlqb1tH+ruiCeLqg5YuIz7yO6qx1lqKwtCajKKAqszJVCCFaXUE2/KpNkOV/3
# SIG # End signature block
