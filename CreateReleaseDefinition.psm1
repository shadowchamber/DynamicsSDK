<#
.SYNOPSIS
    Queries, creates and removes VSTS Release Definitions for release management of 
    Dynamics AX 7.0 projects.

.DESCRIPTION
    This script is intended for use in the Dynamics AX Development setup
    process to create a new release definition.

.NOTES
    The release definition can be exported from VSTS through REST API.
    This is a preview release and is not meant to be executed at deployment. The user needs to run the script manually to get the release definition.

    Copyright © 2016 Microsoft. All rights reserved.
#>

<#
.SYNOPSIS
    Construct a header with authentication information for invoking the VSTS REST API.
#>
function Get-VSTSRestApiHeader
{
    [Cmdletbinding()]
    Param(
        [Parameter(Mandatory=$false, HelpMessage="The user name to authenticate to Visual Studio Team Services.")]
        [string]$AlternateUsername=$null,
    
        [Parameter(Mandatory=$false, HelpMessage="The password of the user to authenticate to Visual Studio Team Services.")]
        [string]$AlternatePassword=$null,

        [Parameter(Mandatory=$false, HelpMessage="The personal access token to use for authentication to Visual Studio Team Services.")]
        [string]$VSTSAccessToken=$null
    )

    if ($VSTSAccessToken)
    {
        $BasicAuth = [System.Text.Encoding]::UTF8.GetBytes("PAT:$($VSTSAccessToken)")
    }
    elseif ($AlternateUsername -and $AlternatePassword)
    {
        $BasicAuth = [System.Text.Encoding]::UTF8.GetBytes("$($AlternateUsername):$($AlternatePassword)")
    }
    else
    {
        throw "No VSTS authentication information has been provided."
    }

    $BasicAuthBase64 = [System.Convert]::ToBase64String($BasicAuth)
    $RestHeaders = @{Authorization=("Basic {0}" -f $BasicAuthBase64)}
    
    return $RestHeaders
}


function Get-AX7ReleaseDefinition
{
    [Cmdletbinding()]
    Param(
        [Parameter(Mandatory=$true, HelpMessage="The Visual Studio Team Services project collection URL to connect to.")]
        [string]$VSO_ProjectCollection,

        [Parameter(Mandatory=$true, HelpMessage="The Visual Studio Team Services project name where the release definition template will be checked in.")]
        [string]$ProjectName,

        [Parameter(Mandatory=$false, HelpMessage="The branch name to use for the release definition.")]
        [string]$Branch = "Main",

        [Parameter(Mandatory=$false, HelpMessage="The user name to authenticate to Visual Studio Team Services.")]
        [string]$AlternateUsername=$null,
    
        [Parameter(Mandatory=$false, HelpMessage="The password of the user to authenticate to Visual Studio Team Services.")]
        [string]$AlternatePassword=$null,

        [Parameter(Mandatory=$false, HelpMessage="The personal access token to use for authentication to Visual Studio Team Services.")]
        [string]$VSTSAccessToken=$null,

        [Parameter(Mandatory=$false, HelpMessage="The name of the release definition.")]
        [string]$ReleaseDefinitionName = "AX7 - Release $($Branch)"
    )

    $RestUrlGetAllReleaseDefinitions = "$($VSO_ProjectCollection)/$($ProjectName)/_apis/Release/definitions/"
    $RestHeaders = Get-VSTSRestApiHeader -AlternateUsername $AlternateUsername -AlternatePassword $AlternatePassword -VSTSAccessToken $VSTSAccessToken

    $ExistingReleaseDefinition = $null
    $ExistingReleaseDefinitions = Invoke-RestMethod -Uri $RestUrlGetAllReleaseDefinitions -ContentType "application/json" -Headers $RestHeaders -Method Get
    
    if ($ExistingReleaseDefinitions.Count -gt 0)
    {
        foreach ($ReleaseDefinition in $ExistingReleaseDefinitions.value)
        {
            if ($ReleaseDefinition.name -ieq $ReleaseDefinitionName)
            {
                $ExistingReleaseDefinition = $ReleaseDefinition
            }
        }
    }

    return $ExistingReleaseDefinition
}

function Remove-AX7ReleaseDefinition
{
    [Cmdletbinding()]
    Param(
        [Parameter(Mandatory=$true, HelpMessage="The Visual Studio Team Services project collection URL to connect to.")]
        [string]$VSO_ProjectCollection,

        [Parameter(Mandatory=$true, HelpMessage="The Visual Studio Team Services project name where the release definition will be checked in.")]
        [string]$ProjectName,

        [Parameter(Mandatory=$false, HelpMessage="The user name to authenticate to Visual Studio Team Services.")]
        [string]$AlternateUsername=$null,
    
        [Parameter(Mandatory=$false, HelpMessage="The password of the user to authenticate to Visual Studio Team Services.")]
        [string]$AlternatePassword=$null,

        [Parameter(Mandatory=$false, HelpMessage="The personal access token to use for authentication to Visual Studio Team Services.")]
        [string]$VSTSAccessToken=$null,

        [Parameter(Mandatory=$true, HelpMessage="The ID of the release definition to remove.")]
        [string]$ReleaseDefinitionId
    )

    $RestUrl = "$($VSO_ProjectCollection)/$($ProjectName)/_apis/Release/definitions/"
    $RestHeaders = Get-VSTSRestApiHeader -AlternateUsername $AlternateUsername -AlternatePassword $AlternatePassword -VSTSAccessToken $VSTSAccessToken

    # Create the rest url for deleting the release definition. 
    # Note - the api version is required for this rest url otherwise it throws an error similar to this - No api-version was supplied for the \"DELETE\" request
    $RestUrlDeleteReleaseDefinition = "$($RestUrl)$($ReleaseDefinitionId)?api-version=3.0-preview.1"
    $NoResponseData = Invoke-RestMethod -Uri $RestUrlDeleteReleaseDefinition -ContentType "application/json" -Headers $RestHeaders -Method Delete
}

function New-AX7ReleaseDefinition
{
    [Cmdletbinding()]
    Param(
        [Parameter(Mandatory=$true, HelpMessage="The Visual Studio Team Services project collection URL to connect to.")]
        [string]$VSO_ProjectCollection,

        [Parameter(Mandatory=$true, HelpMessage="The Visual Studio Team Services project name where the release definition will be checked in.")]
        [string]$ProjectName,

        [Parameter(Mandatory=$false, HelpMessage="The branch name to use the create the release definition.")]
        [string]$Branch = "Main",

        [Parameter(Mandatory=$false, HelpMessage="The user name to authenticate to Visual Studio Team Services.")]
        [string]$AlternateUsername=$null,
    
        [Parameter(Mandatory=$false, HelpMessage="The password of the user to authenticate to Visual Studio Team Services.")]
        [string]$AlternatePassword=$null,

        [Parameter(Mandatory=$false, HelpMessage="The personal access token to use for authentication to Visual Studio Team Services.")]
        [string]$VSTSAccessToken=$null,

        [Parameter(Mandatory=$false, HelpMessage="The name of the release definition.")]
        [string]$ReleaseDefinitionName = "AX7 - Release $($Branch)",

        [Parameter(Mandatory=$false, HelpMessage="The name of the release definition environment.")]
        [string]$ReleaseDefinitionEnvironmentName = "Sandbox Test",

        [Parameter(Mandatory=$true, HelpMessage="The build definition object.")]
        $BuildDefinition
    )

    # Create the rest url for creating the release definition. 
    # Note - the api version is required for this rest url otherwise it throws an error similar to this - No api-version was supplied for the \"POST\" request
    $RestUrl = "$($VSO_ProjectCollection)/$($ProjectName)/_apis/Release/definitions?api-version=3.0-preview.1"
    $RestHeaders = Get-VSTSRestApiHeader -AlternateUsername $AlternateUsername -AlternatePassword $AlternatePassword -VSTSAccessToken $VSTSAccessToken
 
    # Get details from $BuildDefinition
    if ($BuildDefinition.name)
    {
        $BuildDefinitionName = $BuildDefinition.name
    }
    else
    {
        throw "Release definition cannot be created with missing build definition name."
    }

    if ($BuildDefinition.id)
    {
        $BuildDefinitionId = $BuildDefinition.id
    }
    else
    {
        throw "Release definition cannot be created with missing build definition id."
    }

    if ($BuildDefinition.project.id)
    {
        $ProjectId = $BuildDefinition.project.id
    }
    else
    {
        throw "Release definition cannot be created with missing project id."
    }

    if ($BuildDefinition.queue.id)
    {
        $AgentQueueId = $BuildDefinition.queue.id
    }
    else
    {
        throw "Release definition cannot be created with missing queue id."
    }
    
    $ReleaseDefinitionBody = @"
{
  "artifacts": [
    {
      "type": "Build",
      "alias": "$($BuildDefinitionName)",
      "definitionReference": {
        "definition": {
          "id": "$($BuildDefinitionId)",
          "name": "$($BuildDefinitionName)"
        },
        "project": {
          "id": "$($ProjectId)",
          "name": "$($ProjectName)"
        }
      }
    }
  ],
  "environments": [
    {
      "name": "$($ReleaseDefinitionEnvironmentName)",
      "rank": 1,
      "variables": {
        "AuthenticationThumbprint": {
          "value": ""
        },
        "BuildConfiguration": {
          "value": "Release"
        },
        "BuildPlatform": {
          "value": "Any CPU"
        },
        "CloudUri": {
          "value": ""
        },
        "FederationRealm": {
          "value": ""
        },
        "NetworkDomain": {
          "value": ""
        },
        "TestAssembly": {
          "value": "**\\*Test*.dll"
        },
        "TestFilter": {
          "value": ""
        },
        "UserName": {
          "value": ""
        }
      },
      "preDeployApprovals": {
        "approvals": [
          {
            "rank": 1,
            "isAutomated": true,
            "isNotificationOn": false
          }
        ]
      },
      "deployStep": {
        "tasks": [
          {
            "taskId": "e213ff0f-5d5c-4791-802d-52ea3e7be1f1",
            "version": "*",
            "name": "Test Start",
            "enabled": true,
            "alwaysRun": false,
            "continueOnError": false,
            "timeoutInMinutes": 0,
            "definitionType": "task",
            "inputs": {
              "scriptType": "filePath",
              "scriptName": "`$(DynamicsSDK)\\Test\\SandboxTestStart.ps1",
              "arguments": "-BuildNumber \"`$(Build.SourceBranch)@`$(Build.BuildNumber)\" -CloudUri \"`$(CloudUri)\" -UserName \"`$(UserName)\" -FederationRealm \"`$(FederationRealm)\" -NetworkDomain \"`$(NetworkDomain)\" -AuthenticationThumbprint \"`$(AuthenticationThumbprint)\"",
              "workingFolder": ""
            }
          },
          {
            "taskId": "ef087383-ee5e-42c7-9a53-ab56c98420f9",
            "version": "*",
            "name": "Execute Tests",
            "enabled": true,
            "alwaysRun": false,
            "continueOnError": true,
            "timeoutInMinutes": 0,
            "definitionType": "task",
            "inputs": {
              "testAssembly": "`$(Agent.ReleaseDirectory)\\SandboxDeployedPackages\\`$(TestAssembly)",
              "testFiltercriteria": "`$(TestFilter)",
              "runSettingsFile": "`$(Agent.ReleaseDirectory)\\SandboxDeployedPackages\\SandboxTest.runsettings",
              "overrideTestrunParameters": "",
              "codeCoverageEnabled": "false",
              "runInParallel": "false",
              "vsTestVersion": "14.0",
              "pathtoCustomTestAdapters": "",
              "otherConsoleOptions": "/Platform:X64 /InIsolation /UseVsixExtensions:true",
              "testRunTitle": "Sandbox Test - `$(Build.DefinitionName)",
              "platform": "`$(BuildPlatform)",
              "configuration": "`$(BuildConfiguration)",
              "publishRunAttachments": "true"
            }
          },
          {
            "taskId": "e213ff0f-5d5c-4791-802d-52ea3e7be1f1",
            "version": "*",
            "name": "Test End",
            "enabled": true,
            "alwaysRun": true,
            "continueOnError": true,
            "timeoutInMinutes": 0,
            "definitionType": "task",
            "inputs": {
              "scriptType": "filePath",
              "scriptName": "`$(DynamicsSDK)\\Test\\SandboxTestEnd.ps1",
              "arguments": "-BuildNumber \"`$(Build.SourceBranch)@`$(Build.BuildNumber)\"",
              "workingFolder": ""
            }
          }
        ]
      },
      "postDeployApprovals": {
        "approvals": [
          {
            "rank": 1,
            "isAutomated": true,
            "isNotificationOn": false,
            "id": 15
          }
        ]
      },
      "queueId": $($AgentQueueId),
      "runOptions": {
        "EnvironmentOwnerEmailNotificationType": "Never",
        "skipArtifactsDownload": "False",
        "TimeoutInMinutes": "0"
      },
      "environmentOptions": {
        "emailNotificationType": "Never",
        "emailRecipients": null,
        "skipArtifactsDownload": false,
        "timeoutInMinutes": 0,
        "enableAccessToken": false
      },
      "demands": [
        "DynamicsSDK",
        "Agent.Version -gtVersion 1.87"
      ],
      "conditions": [

      ],
      "executionPolicy": {
        "concurrencyCount": 0,
        "queueDepthCount": 0
      },
      "schedules": [

      ],
      "retentionPolicy": {
        "daysToKeep": 60,
        "releasesToKeep": 3,
        "retainBuild": false
      }
    }
  ],
  "name": "$($ReleaseDefinitionName)",
  "releaseNameFormat": "Release-`$(Date:yyyy).`$(Date:MM).`$(Date:dd)`$(Rev:.r)",
  "retentionPolicy": {
    "daysToKeep": 60
  }
}
"@

    $NewReleaseDefinition = Invoke-RestMethod -Uri $RestUrl -ContentType "application/json" -Body $ReleaseDefinitionBody -Headers $RestHeaders -Method Post
    
    return $NewReleaseDefinition
}


Export-ModuleMember -Function New-AX7ReleaseDefinition, Get-AX7ReleaseDefinition, Remove-AX7ReleaseDefinition
# SIG # Begin signature block
# MIIjngYJKoZIhvcNAQcCoIIjjzCCI4sCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAVWpPlFGCMDdsu
# Ql3cLAlvAHyZH0RmVRgN4kVbKMjsTqCCDYEwggX/MIID56ADAgECAhMzAAAB32vw
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
# BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgEzwVVZtI
# uSaAgwbWhi9s3UMIexW+3oVhNsWkhbKhNQwwQgYKKwYBBAGCNwIBDDE0MDKgFIAS
# AE0AaQBjAHIAbwBzAG8AZgB0oRqAGGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbTAN
# BgkqhkiG9w0BAQEFAASCAQBpG87Vu2yD3wh/qKfzVOhJVMGGryGwhH/NGjbPBDfa
# 5zGeMOl+BW9UqSVJsyhkgacmlXH2MotGQLfsQMiZkBWxlwMc5D6IWSBZjP2DsoxT
# 4xgncMLM3AQ1/Pi0lOvl2OWpRDHFYg9G5ef6D+RGZ9ICLZxwRk1Iz6Ekvyh66NEK
# kP0xQeKt46xgeYSZGJvz7WqOjGTXXya+y6jV3gSccVxXiFzzgYlCusLD6htztnFG
# Sb63aXhNsgyxNtK29uDEqeys8UXRJ5PlOZ8NwzSqtzsZGJjfh89uWqj5L6IyhsDA
# s93GlOQAg2eheSKXyrT27XQJ62aS6hKYh35u+6colwRAoYIS/TCCEvkGCisGAQQB
# gjcDAwExghLpMIIS5QYJKoZIhvcNAQcCoIIS1jCCEtICAQMxDzANBglghkgBZQME
# AgEFADCCAVkGCyqGSIb3DQEJEAEEoIIBSASCAUQwggFAAgEBBgorBgEEAYRZCgMB
# MDEwDQYJYIZIAWUDBAIBBQAEINIStpL0FOAyIJNXltaLyI1C6KbWsKX4WJhDJ/Sn
# lMYZAgZgPSuf0i4YEzIwMjEwMzAzMDMxMDAwLjY4M1owBIACAfSggdikgdUwgdIx
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
# BDAvBgkqhkiG9w0BCQQxIgQgAfeA91Gixb6nlfBlC0ABWXY/omtkDXEZqDTWZvmi
# ZUkwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCBRPwE8jOpzdJ5wdE8soG1b
# S846dP7vyFpaj5dzFV6t3jCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwAhMzAAABQa9/Updc8txFAAAAAAFBMCIEIDI8k+AZ2+qKrT0TjZ7LmA5G
# C+u5xZScebfL24KQIuXCMA0GCSqGSIb3DQEBCwUABIIBAFYxVu4FX6Zr8XG7wEUR
# a3z24idxJv4HuXmPeZcj/p+w8P8p65JK2yVb5NmUR2Q9qSK9c5zIg6iQe/ijhd2k
# t9k62zbcpVFouofHg+sT+QhQqtWuRhGTM47lshZ8IROm8tRdKXuemV0gmX+/1rcC
# rDwPSTrW4uikHMjBsYIoqfJ7CL2Fmt2g4aOOdPRKaeU1Vg3c1hyjICdH/Y6Rp1N4
# +vVGv3wxIv+gF+YyVHTdBXNQvHQeRj/GMBLGICHQqNJOLXKv/n0moL8Tjy9Hc30Y
# VKeKysJXaFaF0heIq7z/IBNQL9tba2+f24SkIOhbFkvwh95fY/l0VJSadXkXQ1qt
# 8q0=
# SIG # End signature block
