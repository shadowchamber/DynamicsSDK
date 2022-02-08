<#
.SYNOPSIS
    Start SyncEngine based on list of X++ metadata objects in the provided path.

.DESCRIPTION
    This script is intended for use in the Dynamics AX Development environment
    to do a partial database synchronization during the build process.

.NOTES
    When running through automation, use the -LogPath option to redirect
    output to a log file rather than the console. When the console output is
    used a -Verbose option can be added to get more detailed output.

	The -SourcePath will be searched recursively for .xml files of certain types.
    This folder does not have to be the packages folder, it can be any folder
    containing X++ metadata files.
	
    Copyright © 2017 Microsoft. All rights reserved.
#>
[Cmdletbinding()]
Param(
    [Parameter(Mandatory=$true, HelpMessage="Path to mapped source files")]
    [string]$SourcePath,

    [Parameter(Mandatory=$false, HelpMessage="The full path to the file to write output to (If not specified the output will be written to the host).")]
    [string]$LogPath=$null
)

# Import module for Write-Message and other common functions (Picks up $LogPath variable).
Import-Module $(Join-Path -Path $PSScriptRoot -ChildPath "DynamicsSDKCommon.psm1") -Function "Write-Message", "Get-AX7SdkDeploymentBinariesPath", "Get-AX7SdkDeploymentPackagesPath", "Get-AX7SdkDeploymentDatabaseServer", "Get-AX7SdkDeploymentDatabaseName"


$FrameworkDirectory = Get-AX7SdkDeploymentBinariesPath
$PackagesPath = Get-AX7SdkDeploymentPackagesPath
$DatabaseServer = Get-AX7SdkDeploymentDatabaseServer
$DatabaseName = Get-AX7SdkDeploymentDatabaseName

<#
.SYNOPSIS
    Create list of base object names of any of the types provided in -ObjectTypes
    given a -SourcePath contains XMLs.
    This will look for both the base object as well as an over-layering delta object.

.OUTPUTS
    System.String[]. Returns the base object names; in case of extensions the suffix of the extension is removed.
#>
function Get-ObjectListOfType(
    [string]$SourcePath,
    [string[]]$ObjectTypes,
    [Switch]$RemoveExtensionSuffix)
{
    $List = @()

    # Get unique list of all XML source files that are one of the object types requested, also check overlayered objects (in Delta folder)
    $List =  Get-ChildItem $SourcePath -Recurse -Include *.xml | Where-Object { ($ObjectTypes -icontains $_.Directory.BaseName) -or ($ObjectTypes -icontains $_.Directory.Parent.BaseName -and $_.Directory.BaseName -eq "Delta") }

    if ($RemoveExtensionSuffix)
    {
        # Filter out file extensions and extension-suffix to get base line object name, then remove duplicate names
        $List = $List | ForEach-Object { $_.BaseName.Split('.')[0] } | Select-Object -Unique
    }
    else
    {
        # Filter out file extensions to get object name, then remove duplicate names
        $List = $List | ForEach-Object { $_.BaseName } | Select-Object -Unique
    }

    return $List
}

<#
.SYNOPSIS
    Add a sync mode and optionally a parameter with object list to the SyncModes and Parameters arrays
    for building the command line for the SyncEngine
#>
function Add-ObjectListToParams(
    [string[]]$ObjectList,
    [string]$SyncMode,
    [string]$Parameter,
    [REF]$SyncModes,
    [REF]$Parameters)
{
    if ($ObjectList.Length -gt 0)
    {
        $SyncModes.Value += $SyncMode

        if ($Parameter)
        {
            $ObjectList = $ObjectList -join ','
            $Parameters.Value += "-$Parameter=`"$ObjectList`""
        }
    }
}

[int]$ExitCode = 0
try
{
    Write-Message "Performing partial synchronization of the database"

    $SyncMode = @()
    $Params = @()

    Write-Message "- Discovering objects to sync"

    # Get lists of objects for different types
    $Types = @("AxTable", "AxView", "AxViewExtension", "AxDataEntityView", "AxDataEntityViewExtension")
    $SyncList = Get-ObjectListOfType -SourcePath $SourcePath -ObjectTypes $Types -RemoveExtensionSuffix
    Add-ObjectListToParams -ObjectList $SyncList -SyncMode "partiallist" -Parameter "synclist" -SyncModes ([REF]$SyncMode) -Parameters ([REF]$Params)

    $Types = @("AxCompositeDataEntityView")
    $SyncList = Get-ObjectListOfType -SourcePath $SourcePath -ObjectTypes $Types
    Add-ObjectListToParams -ObjectList $SyncList -SyncMode "partiallist" -Parameter "compositeEntityList" -SyncModes ([REF]$SyncMode) -Parameters ([REF]$Params)

    $Types = @("AxTableExtension")
    $SyncList = Get-ObjectListOfType -SourcePath $SourcePath -ObjectTypes $Types
    Add-ObjectListToParams -ObjectList $SyncList -SyncMode "partiallist" -Parameter "tableextensionlist" -SyncModes ([REF]$SyncMode) -Parameters ([REF]$Params)

    $Types = @("AxMenuItemDisplay", "AxMenuItemDisplayExtension")
    $SyncList = Get-ObjectListOfType -SourcePath $SourcePath -ObjectTypes $Types -RemoveExtensionSuffix
    Add-ObjectListToParams -ObjectList $SyncList -SyncMode "partialsecurity" -Parameter "midisplaylist" -SyncModes ([REF]$SyncMode) -Parameters ([REF]$Params)

    $Types = @("AxMenuItemAction", "AxMenuItemActionExtension")
    $SyncList = Get-ObjectListOfType -SourcePath $SourcePath -ObjectTypes $Types -RemoveExtensionSuffix
    Add-ObjectListToParams -ObjectList $SyncList -SyncMode "partialsecurity" -Parameter "miactionlist" -SyncModes ([REF]$SyncMode) -Parameters ([REF]$Params)

    $Types = @("AxMenuItemOutput", "AxMenuItemOutputExtension")
    $SyncList = Get-ObjectListOfType -SourcePath $SourcePath -ObjectTypes $Types -RemoveExtensionSuffix
    Add-ObjectListToParams -ObjectList $SyncList -SyncMode "partialsecurity" -Parameter "mioutputlist" -SyncModes ([REF]$SyncMode) -Parameters ([REF]$Params)

    $Types = @("AxForm", "AxFormExtension")
    $SyncList = Get-ObjectListOfType -SourcePath $SourcePath -ObjectTypes $Types -RemoveExtensionSuffix
    Add-ObjectListToParams -ObjectList $SyncList -SyncMode "partialsecurity" -Parameter "formlist" -SyncModes ([REF]$SyncMode) -Parameters ([REF]$Params)

    $Types = @("AxReport")
    $SyncList = Get-ObjectListOfType -SourcePath $SourcePath -ObjectTypes $Types
    Add-ObjectListToParams -ObjectList $SyncList -SyncMode "partialsecurity" -Parameter "reportlist" -SyncModes ([REF]$SyncMode) -Parameters ([REF]$Params)

    $Types = @("AxSecurityPolicy")
    $SyncList = Get-ObjectListOfType -SourcePath $SourcePath -ObjectTypes $Types
    Add-ObjectListToParams -ObjectList $SyncList -SyncMode "partialsecurity" -Parameter "policylist" -SyncModes ([REF]$SyncMode) -Parameters ([REF]$Params)

    $Types = @("AxSecurityRole")
    $SyncList = Get-ObjectListOfType -SourcePath $SourcePath -ObjectTypes $Types
    Add-ObjectListToParams -ObjectList $SyncList -SyncMode "partialsecurity" -Parameter "rolelist" -SyncModes ([REF]$SyncMode) -Parameters ([REF]$Params)

    $Types = @("AxSecurityRoleExtension")
    $SyncList = Get-ObjectListOfType -SourcePath $SourcePath -ObjectTypes $Types
    Add-ObjectListToParams -ObjectList $SyncList -SyncMode "partialsecurity" -Parameter "roleextensionlist" -SyncModes ([REF]$SyncMode) -Parameters ([REF]$Params)

    $Types = @("AxSecurityDuty")
    $SyncList = Get-ObjectListOfType -SourcePath $SourcePath -ObjectTypes $Types
    Add-ObjectListToParams -ObjectList $SyncList -SyncMode "partialsecurity" -Parameter "dutylist" -SyncModes ([REF]$SyncMode) -Parameters ([REF]$Params)

    $Types = @("AxSecurityDutyExtension")
    $SyncList = Get-ObjectListOfType -SourcePath $SourcePath -ObjectTypes $Types
    Add-ObjectListToParams -ObjectList $SyncList -SyncMode "partialsecurity" -Parameter "dutyextensionlist" -SyncModes ([REF]$SyncMode) -Parameters ([REF]$Params)

    $Types = @("AxSecurityPrivilege")
    $SyncList = Get-ObjectListOfType -SourcePath $SourcePath -ObjectTypes $Types
    Add-ObjectListToParams -ObjectList $SyncList -SyncMode "partialsecurity" -Parameter "privilegelist" -SyncModes ([REF]$SyncMode) -Parameters ([REF]$Params)

    $Types = @("AxAggregateDataEntity")
    $SyncList = Get-ObjectListOfType -SourcePath $SourcePath -ObjectTypes $Types
    Add-ObjectListToParams -ObjectList $SyncList -SyncMode "ades" -Parameter "adelist" -SyncModes ([REF]$SyncMode) -Parameters ([REF]$Params)

    $Types = @("AxKPI")
    $SyncList = Get-ObjectListOfType -SourcePath $SourcePath -ObjectTypes $Types
    Add-ObjectListToParams -ObjectList $SyncList -SyncMode "kpis" -Parameter "kpislist" -SyncModes ([REF]$SyncMode) -Parameters ([REF]$Params)

    $Types = @("AxAggregateDimension")
    $SyncList = Get-ObjectListOfType -SourcePath $SourcePath -ObjectTypes $Types
    Add-ObjectListToParams -ObjectList $SyncList -SyncMode "analysisenums" -SyncModes ([REF]$SyncMode)

    $Types = @("AxAggregateMeasurement")
    $SyncList = Get-ObjectListOfType -SourcePath $SourcePath -ObjectTypes $Types
    Add-ObjectListToParams -ObjectList $SyncList -SyncMode "analysisenums" -SyncModes ([REF]$SyncMode)


    # If we have anything to sync the SyncMode will be set
    if ($SyncMode.Length -gt 0)
    {
        $SyncMode = $SyncMode | Select-Object -Unique
        $SyncMode = $SyncMode -join ','
        $Params += "-syncmode=`"$SyncMode`""
        $Params += "-metadatabinaries=`"$PackagesPath`""
        $Params += "-connect=`"Data Source=$DatabaseServer;Initial Catalog=$DatabaseName;Integrated Security=True;Enlist=True;Application Name=SyncEngine`""
        $Params += "-verbosity=Diagnostic"

        $Params = $Params -join ' '

        Write-Message "- Starting Synchronization"

        $SyncEngine = Start-Process -FilePath "$FrameworkDirectory\SyncEngine.exe" -ArgumentList $Params -Wait -PassThru
        if ($SyncEngine.ExitCode -ne 0)
        {
            throw "Synchronize returned with exit code $($SyncEngine.ExitCode)"
        }

        Write-Message "Partial synchronization completed."
    }
    else
    {
        Write-Message "No objects found that need to be synchronized."
    }
}
catch [System.Exception]
{
    Write-Message "- Exception thrown at $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())$([Environment]::NewLine)$($_.Exception.ToString())" -Diag
    Write-Message "Error synchronizing: $($_)" -Error
    $ExitCode = -1
}
Write-Message "Script completed with exit code: $ExitCode"
Exit $ExitCode
# SIG # Begin signature block
# MIIjnAYJKoZIhvcNAQcCoIIjjTCCI4kCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAZN87LRumDTUyC
# 8Dd/kU6z9RQZaRQjd+zBHfxvWlkkqqCCDYEwggX/MIID56ADAgECAhMzAAAB32vw
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
# BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgNQbr+10k
# Gt3DBSslpCLgWBI9NqZaHH5//tMTjPl17IowQgYKKwYBBAGCNwIBDDE0MDKgFIAS
# AE0AaQBjAHIAbwBzAG8AZgB0oRqAGGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbTAN
# BgkqhkiG9w0BAQEFAASCAQCFwH1aYe+Dd8byZp/wZpeosgAY+8M5L+G+yUnvaFLk
# lVO3GsdqxFc1GK7nIa2w5BBAVtOKGoF/Y7Gg/yKSz+GiqdjDOv2MnZhxZViJ+Gg2
# cr1/op7BXS7u3MaEwKcGfH1mhEBzjLtJwSFmcSRMvBJxGZvDgbNgjZtDEaoomSfF
# LIHa5uilG1gvUqBrm9v+5CyMvx4B0H4yzLM9fRxKSNkhfiWJBl42yqAJABYxAGp3
# A9zCiq/ejB1m53vYpkVJeUJal9l2mRMj4n3HMX8zIEVs3DKLCxz1suiD+5FhIEHN
# eZ2zZIyAgONRVgXjYnbnTNZfZUkdbOumeWAiulB9KqbFoYIS+zCCEvcGCisGAQQB
# gjcDAwExghLnMIIS4wYJKoZIhvcNAQcCoIIS1DCCEtACAQMxDzANBglghkgBZQME
# AgEFADCCAVkGCyqGSIb3DQEJEAEEoIIBSASCAUQwggFAAgEBBgorBgEEAYRZCgMB
# MDEwDQYJYIZIAWUDBAIBBQAEIPUBVQq27sRzDc/oNHysOkE9T3PD6qOjUMHiRG9V
# 8z1YAgZgPQYO22cYEzIwMjEwMzAzMDMwOTU4LjE0M1owBIACAfSggdikgdUwgdIx
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
# LwYJKoZIhvcNAQkEMSIEIAs/SIc/+a6ggJ4e5ZM1UaesD9wjAq2zSIqsmkEemsdx
# MIH6BgsqhkiG9w0BCRACLzGB6jCB5zCB5DCBvQQgi+vOjaqNTvKOZGut49HXrqtw
# Uj2ZCnVOurBwfgQxmxMwgZgwgYCkfjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0Eg
# MjAxMAITMwAAAT7OyndSxfc0KwAAAAABPjAiBCChpDX9KcSu9+QcwFp6NltYmc7U
# 6h6t2X9Yrm71JhU+AjANBgkqhkiG9w0BAQsFAASCAQAQPS+/9JkMcv6oHisCAiGu
# 9u477YeDyyYFdHpq2ePoNSJMYZku5GSOAx7cAwn+4XF6ch1lbM6aSVrBMDJ++ojD
# dy4R/tlqzcyQYw90JlTPcLYYmJ6Xe+1dofkmeSxlO7a5Eg35NPHoI2D0N0pgaQ49
# gI0qXrClge6nO3DiyQJZrbFqWpUCuszy6GggE8r5cuWedL422fWUR8EyFO/cdCeU
# J0Ui0AuFi8+ibIjt2lzsH3aL/oQpgEX/JDT9H/qpuOUIJErxyFBBGNwYiGiXPcuB
# Zb3qpkjSwfP0IGlpmmz9jgPJTk02VHaeH9pXW2sZO3FIJ5BM4ORC/citTfH7JFOJ
# SIG # End signature block
