<#
.SYNOPSIS
    Instrumentation for telemetry on build events.

.DESCRIPTION
    This script is intended for use in the Dynamics AX Development environment
    to automate the build process.

.NOTES
    When running through automation, use the -LogPath option to redirect
    output to a log file rather than the console. When the console output is
    used a -Verbose option can be added to get more detailed output.

    Copyright © 2016 Microsoft. All rights reserved.
#>
[CmdletBinding()]
Param(
    [Switch]$BuildStart,
    [Switch]$BuildEnd,	
    [Switch]$TestStart,
    [Switch]$TestEnd,
    [Switch]$SandboxTestStart,
    [Switch]$SandboxTestEnd,
    [Switch]$BuildMarker,
    [Switch]$DeployMarker,
    [Switch]$TestMarker,
    [Switch]$ExceptionMarker,
    [Switch]$CreateReleaseDefinitionMarker,
    [Switch]$Disable,
    [Switch]$TaskPrepareForBuildStart,
    [Switch]$TaskPrepareForBuildStop,
    [Switch]$TaskSetModelVersionsStart,
    [Switch]$TaskSetModelVersionsStop,
    [Switch]$TaskBuildStart,
    [Switch]$TaskBuildEnd,
    [Switch]$TaskGenerateProjFilesStart,
    [Switch]$TaskGenerateProjFilesStop,
    [Switch]$TaskDBSyncStart,
    [Switch]$TaskDBSyncStop,
    [Switch]$TaskDeployReportsStart,
    [Switch]$TaskDeployReportsStop,
    [Switch]$TaskGeneratePackagesStart,
    [Switch]$TaskGeneratePackagesStop,
    [Switch]$TaskTestStart,
    [Switch]$TaskTestStop,
    [Parameter(Mandatory=$false)]
    [string]$BuildNumber,
    [Parameter(Mandatory=$false)]
    [string]$ExceptionString = "",
    [Parameter(Mandatory=$false)]
    [string]$DataArgument = "")

# Import module for Write-Message and other common functions (Picks up $LogPath variable).
Import-Module $(Join-Path -Path $PSScriptRoot -ChildPath "DynamicsSDKCommon.psm1") -Function "Write-Message", "Get-AX7SdkDeploymentBinariesPath", "Get-AX7SdkTeamFoundationServerUrl"


function Load-DllinMemory([string] $dllPath)
{
    #try catch as not all dll exist in RTM version, some dependency/dll are introduced at update 1 or later
    #powershell cannot unload dll once it's loaded, the trick is to create an in-memory copy of the dll than load it
    #after the loading of in-memory dll, the physical dll stay unlocked

    try
    {
        $bytes = [System.IO.File]::ReadAllBytes($dllPath)
        [System.Reflection.Assembly]::Load($bytes) >$null
    }
    catch
    {}
}

[int]$ExitCode = 0
try
{
    if ($Disable)
    {
        Write-Message "Instrumentation disabled."
    }
    else
    {
        $DeploymentBinariesPath = Get-AX7SdkDeploymentBinariesPath
        if (!$DeploymentBinariesPath)
        {
            throw "No deployment binaries path found in Dynamics SDK registry."
        }
        if (!(Test-Path -Path $DeploymentBinariesPath))
        {
            throw "Deployment binaries path from Dynamics SDK registry does not exist: $DeploymentBinariesPath"
        }
        
        $AssemblyPath = Join-Path -Path $DeploymentBinariesPath -Childpath "Microsoft.Dynamics.ApplicationPlatform.Development.Instrumentation.dll"
        if (!(Test-Path -Path $AssemblyPath))
        {
            throw "Instrumentation assembly does not exist: $AssemblyPath"
        }
        Write-Message "- Adding type from: $AssemblyPath" -Diag 
		Load-DllinMemory -dllPath $AssemblyPath

        # VSTS Agent defines $env variables for the build context
        $BuildDefinition = if ($env:SYSTEM_DEFINITIONID) { $env:SYSTEM_DEFINITIONID } else { "" }
        $VSOInstance = if ($env:SYSTEM_COLLECTIONID) { $env:SYSTEM_COLLECTIONID } else { "" }

        # Create/use guid unique to each build... Use VSTS task variables to stay in context of the build
        if ($env:ALMActivityID)
        {
            $ALMActivityID = $env:ALMActivityID
        }
        else
        {
            $ALMActivityID = New-Guid
            Write-Output ("##vso[task.setvariable variable=ALMActivityID]$ALMActivityID")
            $env:ALMActivityID = $ALMActivityID
        }

        # Create build data object with VSTS $env variables to pass as JSON string to telemetry
        $BuildData = New-Object -TypeName PSObject
        # Standard Build Info
        $BuildData | Add-Member COLLECTIONID $VSOInstance
        $BuildData | Add-Member DEFINITIONID $BuildDefinition
        $BuildData | Add-Member ALMACTIVITYID $ALMActivityID
        $dataMember = if ($env:BUILD_REASON) { $env:BUILD_REASON } else { "" }
        $BuildData | Add-Member BUILD_REASON $dataMember
        $dataMember = if ($env:BUILD_SOURCETFVCSHELVESET) { 1 } else { 0 }
        $BuildData | Add-Member IS_SHELVESET $dataMember
        # Custom AX Build Info
        $dataMember = if ($env:DatabaseBackupToRestore) { 1 } else { 0 }
        $BuildData | Add-Member RESTORE_BACKUP $dataMember
        $dataMember = if ($env:DependencyXml) { 1 } else { 0 }
        $BuildData | Add-Member USING_DEPENDENCYXML $dataMember
        $dataMember = if ($env:DeployReports) { $env:DeployReports } else { 0 }
        $BuildData | Add-Member DEPLOY_REPORTS $dataMember
        $dataMember = if ($env:IncludeBinariesInRuntimePackage) { $env:IncludeBinariesInRuntimePackage } else { 0 }
        $BuildData | Add-Member INCLUDE_BINARIESINPACKAGE $dataMember
        $dataMember = if ($env:ModelVersionExclusions) { 1 } else { 0 }
        $BuildData | Add-Member EXCLUDE_MODELVERSIONING $dataMember
        $dataMember = if ($env:PackagingExclusions) { 1 } else { 0 }
        $BuildData | Add-Member EXCLUDE_MODULEPACKAGING $dataMember
        $dataMember = if ($env:SkipRuntimePackageGeneration) { $env:SkipRuntimePackageGeneration } else { 0 }
        $BuildData | Add-Member SKIP_RUNTIMEPACKAGING $dataMember
        $dataMember = if ($env:SkipSourcePackageGeneration) { $env:SkipSourcePackageGeneration } else { 0 }
        $BuildData | Add-Member SKIP_SOURCEPACKAGING $dataMember
        $dataMember = if ($env:SkipSyncEngine) { $env:SkipSyncEngine } else { 0 }
        $BuildData | Add-Member SKIP_SYNCENGINE $dataMember
        $dataMember = if ($env:SyncEngineFallbackToNative) { $env:SyncEngineFallbackToNative } else { 0 }
        $BuildData | Add-Member USING_NATIVESYNC $dataMember
        $dataMember = if ($env:TestFilter) { 1 } else { 0 }
        $BuildData | Add-Member USING_TESTFILTER $dataMember

        $oldVerbosity = $verbosepreference
        $verbosepreference = 'SilentlyContinue' # Workaround for PowerShell verbosity GitHub issue 1522
        $volumeData = Get-PSDrive -PSProvider FileSystem | Select-Object Root,Description,Used,Free
        $verbosepreference = $oldVerbosity
        $BuildData | Add-Member VOLUMES $volumeData
        
        [string]$dataString = $BuildData | ConvertTo-Json
        
        # Get all the methods available for the alm event source, this is useful for backwards compatibility
        $AXDeveloperALMEventSourceMethods = [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource].GetMethods().Name

        if ($BuildStart -and $AXDeveloperALMEventSourceMethods -inotcontains "EventWriteDevALMTaskBuildStart")
        {
           [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMBuildExecutionStart($VSOInstance, $BuildDefinition)
           Write-Message "- Event: EventWriteDevALMBuildExecutionStart" -Diag
        }
        elseif ($BuildEnd -and $AXDeveloperALMEventSourceMethods -inotcontains "EventWriteDevALMTaskBuildStart")
        {
           [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMBuildExecutionStop($VSOInstance, $BuildDefinition)
           Write-Message "- Event: EventWriteDevALMBuildExecutionStop" -Diag
        }
        elseif ($TestStart)
        {
           [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMTestExecutionStart($VSOInstance, $BuildDefinition)
           Write-Message "- Event: EventWriteDevALMTestExecutionStart" -Diag
        }
        elseif ($TestEnd)
        {
           [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMTestExecutionStop($VSOInstance, $BuildDefinition)
           Write-Message "- Event: EventWriteDevALMTestExecutionStop" -Diag
        }
        elseif ($SandboxTestStart -and $AXDeveloperALMEventSourceMethods -icontains "EventWriteDevALMSandboxTestExecutionStart")
        {
           [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMSandboxTestExecutionStart($VSOInstance, $BuildDefinition)
           Write-Message "- Event: EventWriteDevALMSandboxTestExecutionStart" -Diag
        }
        elseif ($SandboxTestEnd -and $AXDeveloperALMEventSourceMethods -icontains "EventWriteDevALMSandboxTestExecutionStop")
        {
           [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMSandboxTestExecutionStop($VSOInstance, $BuildDefinition)
           Write-Message "- Event: EventWriteDevALMSandboxTestExecutionStop" -Diag
        }
        elseif ($BuildMarker)
        {
           [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMBuild($dataString)
           Write-Message "- Event: EventWriteDevALMBuild" -Diag
        }
        elseif ($DeployMarker)
        {
           [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMDeploy($DataArgument)
           Write-Message "- Event: EventWriteDevALMDeploy" -Diag
        }
        elseif ($TestMarker)
        {
           [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMValidation($dataString)
           Write-Message "- Event: EventWriteDevALMValidation" -Diag
        }
        elseif ($ExceptionMarker -and $AXDeveloperALMEventSourceMethods -icontains "EventWriteDevALMException")
        {
           [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMException($ALMActivityID, $ExceptionString)
           Write-Message "- Event: EventWriteDevALMException" -Diag
        }
        elseif ($ExceptionMarker)
        {
           [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMUnhandledException($ExceptionString)
           Write-Message "- Event: EventWriteDevALMUnhandledException" -Diag
        }
        elseif ($CreateReleaseDefinitionMarker -and $AXDeveloperALMEventSourceMethods -icontains "EventWriteDevALMCreateReleaseDefinition")
        {
           [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMCreateReleaseDefinition($DataArgument)
           Write-Message "- Event: EventWriteDevALMCreateReleaseDefinition" -Diag
        }
        elseif ($TaskPrepareForBuildStart -and $AXDeveloperALMEventSourceMethods -icontains "EventWriteDevALMTaskPrepareForBuildStart")
        {
           [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMTaskPrepareForBuildStart($ALMActivityID, $DataArgument)
           Write-Message "- Event: EventWriteDevALMTaskPrepareForBuildStart" -Diag
        }
        elseif ($TaskPrepareForBuildStop -and $AXDeveloperALMEventSourceMethods -icontains "EventWriteDevALMTaskPrepareForBuildStop")
        {
           [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMTaskPrepareForBuildStop($ALMActivityID, $DataArgument)
           Write-Message "- Event: EventWriteDevALMTaskPrepareForBuildStop" -Diag
        }
        elseif ($TaskSetModelVersionsStart -and $AXDeveloperALMEventSourceMethods -icontains "EventWriteDevALMTaskSetModelVersionsStart")
        {
           [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMTaskSetModelVersionsStart($ALMActivityID, $DataArgument)
           Write-Message "- Event: EventWriteDevALMTaskSetModelVersionsStart" -Diag
        }
        elseif ($TaskSetModelVersionsStop -and $AXDeveloperALMEventSourceMethods -icontains "EventWriteDevALMTaskSetModelVersionsStop")
        {
           [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMTaskSetModelVersionsStop($ALMActivityID, $DataArgument)
           Write-Message "- Event: EventWriteDevALMTaskSetModelVersionsStop" -Diag
        }
        elseif ($TaskGenerateProjFilesStart -and $AXDeveloperALMEventSourceMethods -icontains "EventWriteDevALMTaskGenerateProjFilesStart")
        {
           [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMTaskGenerateProjFilesStart($ALMActivityID, $DataArgument)
           Write-Message "- Event: EventWriteDevALMTaskGenerateProjFilesStart" -Diag
        }
        elseif ($TaskGenerateProjFilesStop -and $AXDeveloperALMEventSourceMethods -icontains "EventWriteDevALMTaskGenerateProjFilesStop")
        {
           [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMTaskGenerateProjFilesStop($ALMActivityID, $DataArgument)
           Write-Message "- Event: EventWriteDevALMTaskGenerateProjFilesStop" -Diag
        }
        elseif (($TaskBuildStart -or $BuildStart) -and $AXDeveloperALMEventSourceMethods -icontains "EventWriteDevALMTaskBuildStart")
        {
           [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMTaskBuildStart($ALMActivityID, $DataArgument)
           Write-Message "- Event: EventWriteDevALMTaskBuildStart" -Diag
        }
        elseif (($TaskBuildStop -or $BuildEnd) -and $AXDeveloperALMEventSourceMethods -icontains "EventWriteDevALMTaskBuildStop")
        {
           [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMTaskBuildStop($ALMActivityID, $DataArgument)
           Write-Message "- Event: EventWriteDevALMTaskBuildStop" -Diag
        }
        elseif ($TaskDBSyncStart -and $AXDeveloperALMEventSourceMethods -icontains "EventWriteDevALMTaskDBSyncStart")
        {
           [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMTaskDBSyncStart($ALMActivityID, $DataArgument)
           Write-Message "- Event: EventWriteDevALMTaskDBSyncStart" -Diag
        }
        elseif ($TaskDBSyncStop -and $AXDeveloperALMEventSourceMethods -icontains "EventWriteDevALMTaskDBSyncStop")
        {
           [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMTaskDBSyncStop($ALMActivityID, $DataArgument)
           Write-Message "- Event: EventWriteDevALMTaskDBSyncStop" -Diag
        }
        elseif ($TaskDeployReportsStart -and $AXDeveloperALMEventSourceMethods -icontains "EventWriteDevALMTaskDeployReportsStart")
        {
           [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMTaskDeployReportsStart($ALMActivityID, $DataArgument)
           Write-Message "- Event: EventWriteDevALMTaskDeployReportsStart" -Diag
        }
        elseif ($TaskDeployReportsStop -and $AXDeveloperALMEventSourceMethods -icontains "EventWriteDevALMTaskDeployReportsStop")
        {
           [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMTaskDeployReportsStop($ALMActivityID, $DataArgument)
           Write-Message "- Event: EventWriteDevALMTaskDeployReportsStop" -Diag
        }
        elseif ($TaskGeneratePackagesStart -and $AXDeveloperALMEventSourceMethods -icontains "EventWriteDevALMTaskGeneratePackagesStart")
        {
           [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMTaskGeneratePackagesStart($ALMActivityID, $DataArgument)
           Write-Message "- Event: EventWriteDevALMTaskGeneratePackagesStart" -Diag
        }
        elseif ($TaskGeneratePackagesStop -and $AXDeveloperALMEventSourceMethods -icontains "EventWriteDevALMTaskGeneratePackagesStop")
        {
           [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMTaskGeneratePackagesStop($ALMActivityID, $DataArgument)
           Write-Message "- Event: EventWriteDevALMTaskGeneratePackagesStop" -Diag
        }
        elseif ($TaskTestStart -and $AXDeveloperALMEventSourceMethods -icontains "EventWriteDevALMTaskTestStart")
        {
           [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMTaskTestStart($ALMActivityID, $DataArgument)
           Write-Message "- Event: EventWriteDevALMTaskTestStart" -Diag
        }
        elseif ($TaskTestStop -and $AXDeveloperALMEventSourceMethods -icontains "EventWriteDevALMTaskTestStop")
        {
           [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMTaskTestStop($ALMActivityID, $DataArgument)
           Write-Message "- Event: EventWriteDevALMTaskTestStop" -Diag
        }
    }
}
catch [System.Exception]
{
    [Microsoft.Dynamics.ApplicationPlatform.Instrumentation.AXDeveloperALMEventSource]::EventWriteDevALMUnhandledException("Instrumentation Error ($($VSOInstance)/$($BuildDefinition)): $($_.Exception.ToString())")
    
    Write-Message "- Exception thrown at $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())$([Environment]::NewLine)$($_.Exception.ToString())" -Diag
    Write-Message "Error writing event: $($_)" -Error
    $ExitCode = -1
}
Write-Message "Script completed with exit code: $ExitCode"
Exit $ExitCode

# SIG # Begin signature block
# MIIjnAYJKoZIhvcNAQcCoIIjjTCCI4kCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA7hTehlE3gv/fM
# kCyO0tNfBbhUW17pYGHeACFFgZ04FqCCDYEwggX/MIID56ADAgECAhMzAAAB32vw
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
# BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgGjqZ0HQm
# 9fqb10L11xKo1sWV3eweh772t5vYqN776IwwQgYKKwYBBAGCNwIBDDE0MDKgFIAS
# AE0AaQBjAHIAbwBzAG8AZgB0oRqAGGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbTAN
# BgkqhkiG9w0BAQEFAASCAQBP4pK66EiLo5D2HRXB+tYYTIQccuKYsbBvbX0VvzGF
# rw7toyvNahTQ67q21pz7EfZJ7OKH4sCuQibY4DayW+LXK9fn0yfNcJoalNzB89QY
# V6MUi8IkHdW/ifclmuWH34tdsvT5w/6BuogsLAhyh+5I0Ap1YtHSppVpzPMvEThy
# 2FvHCUB33bKeFTfxsznGMsv3rKyQOz70f3slJWivwfhLBrLjBQkbB20UvAKU6H6N
# aGEcyANc2HM3fz0laVfJ0wgw7ZlwW/UZS+jt1wlDyf1V3j4xkXSsXl3kZT3tJNOU
# nW2Ids3EIsAa16GFX65KBjZXIHbvnYgyMhZSz3Po63QQoYIS+zCCEvcGCisGAQQB
# gjcDAwExghLnMIIS4wYJKoZIhvcNAQcCoIIS1DCCEtACAQMxDzANBglghkgBZQME
# AgEFADCCAVkGCyqGSIb3DQEJEAEEoIIBSASCAUQwggFAAgEBBgorBgEEAYRZCgMB
# MDEwDQYJYIZIAWUDBAIBBQAEIFWc38FYe+zTyf1d+gG0IBt4LnTfgClYmUJmy4HO
# VIDJAgZgPQYO27MYEzIwMjEwMzAzMDMxMDAwLjgyMlowBIACAfSggdikgdUwgdIx
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
# LwYJKoZIhvcNAQkEMSIEIBQGyKs42ARDFAcj1PC6QWtEO8MNF+BdYmbofd7QJBWN
# MIH6BgsqhkiG9w0BCRACLzGB6jCB5zCB5DCBvQQgi+vOjaqNTvKOZGut49HXrqtw
# Uj2ZCnVOurBwfgQxmxMwgZgwgYCkfjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0Eg
# MjAxMAITMwAAAT7OyndSxfc0KwAAAAABPjAiBCChpDX9KcSu9+QcwFp6NltYmc7U
# 6h6t2X9Yrm71JhU+AjANBgkqhkiG9w0BAQsFAASCAQA4l6IZVPlUs4l8zvxnU4T0
# RdQHpEJ0Zt7Pvno9Srxuhhni2l4C+w1xGPA92JNFw6diTOVVzTKYNGdDKDf0Ng3f
# PyU0LewRc3hQ/6LOn/3yEgwHQed1vH9c9qKFIBnmUmMvu4+KXDcOIiseru8GFkus
# D2y2ihk3YW3sYPq3X3GvVnuJzotSRkuYUMCgF8TeuirH5VEv1eFN3yoF550Z0ikY
# Na//NuOrhJAvzTRN6x8Kss9tCd3HeB2cSPvCsBWSY0bzrpfV/AvSTBnDqBJWMN6M
# mCZnFqMPPP4bfPluJ4Brwqoyu0VNzROPbr2Nhs+RvbHCAxq5//eBp7AWED7Gv/C4
# SIG # End signature block
