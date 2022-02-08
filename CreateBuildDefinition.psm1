<#
.SYNOPSIS
    Queries, creates and removes VSO Build Definitions for building Dynamics
    AX 7.0 projects.

.DESCRIPTION
    This script is intended for use in the Dynamics AX Development setup
    process to create a new build definition.

.NOTES
    The build definition can be exported from VSTS through REST API.

    Copyright © 2016 Microsoft. All rights reserved.
#>

<#
.SYNOPSIS
    Construct a header with authentication information for invoking the VSO REST API.
#>
function Get-VSORestApiHeader
{
    [Cmdletbinding()]
    Param(
        [Parameter(Mandatory=$false, HelpMessage="The user name to authenticate to Visual Studio Online.")]
        [string]$AlternateUsername=$null,
    
        [Parameter(Mandatory=$false, HelpMessage="The password of the user to authenticate to Visual Studio Online.")]
        [string]$AlternatePassword=$null,

        [Parameter(Mandatory=$false, HelpMessage="The personal access token to use for authentication to Visual Studio Online.")]
        [string]$VSOAccessToken=$null
    )

    if ($VSOAccessToken)
    {
        $BasicAuth = [System.Text.Encoding]::UTF8.GetBytes("PAT:$($VSOAccessToken)")
    }
    elseif ($AlternateUsername -and $AlternatePassword)
    {
        $BasicAuth = [System.Text.Encoding]::UTF8.GetBytes("$($AlternateUsername):$($AlternatePassword)")
    }
    else
    {
        throw "No VSO authentication information has been provided."
    }

    $BasicAuthBase64 = [System.Convert]::ToBase64String($BasicAuth)
    $RestHeaders = @{Authorization=("Basic {0}" -f $BasicAuthBase64)}
    
    return $RestHeaders
}

function New-AX7BuildDefinition
{
    [Cmdletbinding()]
    Param(
        [Parameter(Mandatory=$true, HelpMessage="The Visual Studio Online project collection URL to connect to.")]
        [string]$VSO_ProjectCollection,

        [Parameter(Mandatory=$true, HelpMessage="The Visual Studio Online project name where the build process template will be checked in.")]
        [string]$ProjectName,

        [Parameter(Mandatory=$false, HelpMessage="The user name to authenticate to Visual Studio Online.")]
        [string]$AlternateUsername=$null,
    
        [Parameter(Mandatory=$false, HelpMessage="The password of the user to authenticate to Visual Studio Online.")]
        [string]$AlternatePassword=$null,

        [Parameter(Mandatory=$false, HelpMessage="The personal access token to use for authentication to Visual Studio Online.")]
        [string]$VSOAccessToken=$null,

        [Parameter(Mandatory=$false, HelpMessage="The branch to create the build definition for.")]
        [string]$Branch = "Main",

        [Parameter(Mandatory=$false, HelpMessage="The name of the build definition.")]
        [string]$BuildDefinitionName = "Unified Operations platform - Build $($Branch)",

        [Parameter(Mandatory=$false, HelpMessage="The agent queue ID to use for the default queue in the build definition (1 is Default).")]
        [string]$AgentQueueId = 1,

        [Parameter(Mandatory=$false, HelpMessage="The time zone to use for scheduling daily builds")]
        [string]$BuildScheduleTimeZone = "UTC"
    )

    $RestUrl = "$($VSO_ProjectCollection)/$($ProjectName)/_apis/build/definitions?api-version=2.0"
    $RestHeaders = Get-VSORestApiHeader -AlternateUsername $AlternateUsername -AlternatePassword $AlternatePassword -VSOAccessToken $VSOAccessToken

    # Read the standard build definition from disk
    $BuildDefinitionFilePath = Join-Path -Path $PSScriptRoot -ChildPath "BuildDefinition.json"
    # Convert to PS Object for easy access to properties
    $BuildDefinitionObject = ConvertFrom-Json (Get-Content -Raw $BuildDefinitionFilePath)

    # Set some properties in the build definition based on arguments
    $buildTask = $BuildDefinitionObject.build | Where-Object { $_.displayName -eq "Build the solution" }
    $buildTask.inputs.solution = "`$/$($ProjectName)/Trunk/$($Branch)/AXModulesBuild.proj"
    $BuildDefinitionObject.name = $BuildDefinitionName
    $BuildDefinitionObject.queue.id = $AgentQueueId
    $BuildDefinitionObject.repository.properties.tfvcMapping = "{`"mappings`":[{`"serverPath`":`"`$/$($ProjectName)/Trunk/$($Branch)`",`"mappingType`":`"map`",`"localPath`":`"`"}]}"
    $BuildDefinitionObject.repository.name = $ProjectName
    $BuildDefinitionObject.repository.url = $VSO_ProjectCollection
    $BuildDefinitionObject.repository.defaultBranch = "`$/$($ProjectName)/Trunk/$($Branch)"
    $BuildDefinitionObject.repository.rootFolder = "`$/$($ProjectName)"

    # Convert PS Object back to JSON string
    $BuildDefinitionBody = ConvertTo-Json -Depth 20 $BuildDefinitionObject

    # Invoke VSTS API to create new build definition
    $NewDefinition = Invoke-RestMethod -Uri $RestUrl -ContentType "application/json" -Body $BuildDefinitionBody -Headers $RestHeaders -Method Post

    return $NewDefinition
}

function Get-AX7BuildDefinition
{
    [Cmdletbinding()]
    Param(
        [Parameter(Mandatory=$true, HelpMessage="The Visual Studio Online project collection URL to connect to.")]
        [string]$VSO_ProjectCollection,

        [Parameter(Mandatory=$true, HelpMessage="The Visual Studio Online project name where the build process template will be checked in.")]
        [string]$ProjectName,

        [Parameter(Mandatory=$false, HelpMessage="The branch to create the build definition for.")]
        [string]$Branch = "Main",

        [Parameter(Mandatory=$false, HelpMessage="The user name to authenticate to Visual Studio Online.")]
        [string]$AlternateUsername=$null,
    
        [Parameter(Mandatory=$false, HelpMessage="The password of the user to authenticate to Visual Studio Online.")]
        [string]$AlternatePassword=$null,

        [Parameter(Mandatory=$false, HelpMessage="The personal access token to use for authentication to Visual Studio Online.")]
        [string]$VSOAccessToken=$null,

        [Parameter(Mandatory=$false, HelpMessage="The name of the build definition.")]
        [string]$BuildDefinitionName = "Unified Operations platform - Build $($Branch)"
    )

    $RestUrl = "$($VSO_ProjectCollection)/$($ProjectName)/_apis/build/definitions?api-version=2.0"
    $RestHeaders = Get-VSORestApiHeader -AlternateUsername $AlternateUsername -AlternatePassword $AlternatePassword -VSOAccessToken $VSOAccessToken

    $RestUrlGetBuildDefinition = "$($RestUrl)&name=$($BuildDefinitionName)"
    $ExistingBuildDefinition = Invoke-RestMethod -Uri $RestUrlGetBuildDefinition -ContentType "application/json" -Headers $RestHeaders -Method Get

    return $ExistingBuildDefinition
}

function Remove-AX7BuildDefinition
{
    [Cmdletbinding()]
    Param(
        [Parameter(Mandatory=$true, HelpMessage="The Visual Studio Online project collection URL to connect to.")]
        [string]$VSO_ProjectCollection,

        [Parameter(Mandatory=$true, HelpMessage="The Visual Studio Online project name where the build process template will be checked in.")]
        [string]$ProjectName,

        [Parameter(Mandatory=$false, HelpMessage="The user name to authenticate to Visual Studio Online.")]
        [string]$AlternateUsername=$null,
    
        [Parameter(Mandatory=$false, HelpMessage="The password of the user to authenticate to Visual Studio Online.")]
        [string]$AlternatePassword=$null,

        [Parameter(Mandatory=$false, HelpMessage="The personal access token to use for authentication to Visual Studio Online.")]
        [string]$VSOAccessToken=$null,

        [Parameter(Mandatory=$true, HelpMessage="The ID of the build definition to remove.")]
        [string]$BuildDefinitionId
    )

    $RestUrl = "$($VSO_ProjectCollection)/$($ProjectName)/_apis/build/definitions?api-version=2.0"
    $RestHeaders = Get-VSORestApiHeader -AlternateUsername $AlternateUsername -AlternatePassword $AlternatePassword -VSOAccessToken $VSOAccessToken

    $RestUrlDeleteBuildDefinition = "$($RestUrl)&definitionId=$($BuildDefinitionId)"
    $NoResponseData = Invoke-RestMethod -Uri $RestUrlDeleteBuildDefinition -ContentType "application/json" -Headers $RestHeaders -Method Delete
}

function Get-AX7AgentPoolQueue
{
    [Cmdletbinding()]
    Param(
        [Parameter(Mandatory=$true, HelpMessage="The Visual Studio Online project collection URL to connect to.")]
        [string]$VSO_ProjectCollection,

        [Parameter(Mandatory=$true, HelpMessage="The Visual Studio Online project name where the build process template will be checked in.")]
        [string]$ProjectName,

        [Parameter(Mandatory=$false, HelpMessage="The user name to authenticate to Visual Studio Online.")]
        [string]$AlternateUsername=$null,
    
        [Parameter(Mandatory=$false, HelpMessage="The password of the user to authenticate to Visual Studio Online.")]
        [string]$AlternatePassword=$null,

        [Parameter(Mandatory=$false, HelpMessage="The personal access token to use for authentication to Visual Studio Online.")]
        [string]$VSOAccessToken=$null,

        [Parameter(Mandatory=$false, HelpMessage="The name of the agent pool queue.")]
        [string]$AgentPoolName = "Default"
    )

    # Get all the agent queues that belong to the project.
    $RestUrlGetQueue = "$($VSO_ProjectCollection)/$($ProjectName)/_apis/distributedtask/queues"
    $RestHeaders = Get-VSORestApiHeader -AlternateUsername $AlternateUsername -AlternatePassword $AlternatePassword -VSOAccessToken $VSOAccessToken
    $ExistingQueues = Invoke-RestMethod -Uri $RestUrlGetQueue -ContentType "application/json" -Headers $RestHeaders -Method Get

    # Filter the agent queues to get the one that uses the provided agent pool
    $ExistingQueue = $ExistingQueues.value | Where-Object {$_.pool.name -eq $AgentPoolName}

    return $ExistingQueue
}

Export-ModuleMember -Function New-AX7BuildDefinition, Get-AX7BuildDefinition, Remove-AX7BuildDefinition, Get-AX7AgentPoolQueue

# SIG # Begin signature block
# MIIjnwYJKoZIhvcNAQcCoIIjkDCCI4wCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA374SUDrZfGFV6
# 1jrpCzU+Ct4IZJZ0Jc/9NSekWs4JGaCCDYEwggX/MIID56ADAgECAhMzAAAB32vw
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
# BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgUgmH7OUI
# RLBx0oQqyRR/0bKY//VDKOcWAKEdUh+n4tcwQgYKKwYBBAGCNwIBDDE0MDKgFIAS
# AE0AaQBjAHIAbwBzAG8AZgB0oRqAGGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbTAN
# BgkqhkiG9w0BAQEFAASCAQCOCN980RNO4fhC5KreaeiOwfq79f7woPfiYtnlS7Ew
# ClcDLfGQK2s65THCQEj13sYNbyU8WuIkK1AzIjCJ9uiWUVjlDkfN0hcGJxn/XIpG
# CqUpRqiDjzCSK1HFkd1WThGAfTQFNl8wka5t3n63hBTwcVXOvr3U1CLW6dQOKyfL
# roFn+PsA8dVF0rcY00yFD/qxIrh2OXD97/bhNcxa/z/8rlqijRXdrJXneZDLS+uX
# AY7CwXD/OhAwJACNPcHJBRaGzT0sQJwWu2aHwUmy+/5oQX6hmGpBZTKXjVnqj49r
# VnzO19tc0/KThEu3p+6KpoK6zIoTvJKzR2rORq08rlq+oYIS/jCCEvoGCisGAQQB
# gjcDAwExghLqMIIS5gYJKoZIhvcNAQcCoIIS1zCCEtMCAQMxDzANBglghkgBZQME
# AgEFADCCAVkGCyqGSIb3DQEJEAEEoIIBSASCAUQwggFAAgEBBgorBgEEAYRZCgMB
# MDEwDQYJYIZIAWUDBAIBBQAEID3/8okPM1+Hp+lgQYh6PahOheg0RJG3dNucwTsX
# HRwVAgZgPN+tEjgYEzIwMjEwMzAzMDMxMDAwLjY1MVowBIACAfSggdikgdUwgdIx
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
# AQQwLwYJKoZIhvcNAQkEMSIEIBp49gCW3nzVKyK2fWGCTWd+8OVhJPqzPQ/zw/Ev
# he7RMIH6BgsqhkiG9w0BCRACLzGB6jCB5zCB5DCBvQQgHVl+r8CeBJ0iyX/aGZD2
# YbQ7gk+U7N7BQiTDKAYSHBAwgZgwgYCkfjB8MQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQ
# Q0EgMjAxMAITMwAAATdBj0PnWltvpwAAAAABNzAiBCAi65JPa6/l/RvHv8jkVUIE
# Laur+CfHdrhP7d4NaYF+fTANBgkqhkiG9w0BAQsFAASCAQCJTeDYw1gRAx+fL8XL
# QLF174WB9Cc5hcRkNGW1eiUNos7Hekn8U+93Y/DIDFLRNIXGlBhZWscCmSDr0NQZ
# kIlO2xAykmNPW+wdtksUx9AwTNEQv8af3CULKfrTEyMbY96YhYFk57UIKnySfp9s
# Ld/pMwyU/HzcFd+a+W1LOaPVZBXOBylAeUmGHDtazmHh6VqNI/ved63HVQCSGzN6
# o209FiIYi9ueh+/trnwXArgLZUnPG58yllrdwXx7a4MpX3V4skLBgnOAB1ivPFAA
# H84hvNC3Jw0ti6ExHqo+iAM0gpQBMAHSDK6WLr2DcJSGKoPzPHBEwBiXfBY7/GMs
# Sxj0
# SIG # End signature block
