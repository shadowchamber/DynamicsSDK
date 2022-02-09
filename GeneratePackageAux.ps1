<#
.SYNOPSIS
    Generate deployable packages from the Dynamics AX build output.

.DESCRIPTION
    This script is intended for use in the Dynamics AX Development environment
    to automate the generation of deployable packages in the build process.

.NOTES
    When running through automation, use the -LogPath option to redirect
    output to a log file rather than the console. When the console output is
    used a -Verbose option can be added to get more detailed output.

    A Dynamics AX deployment must exist and the metadata bin folder must contain
    the CreatePackage.psm1 module file, the BaseMetadataDeployablePackage.zip,
    ModelUtil.exe, Microsoft.Dynamics.AXCreateDeployablePackageBase.dll, and
    AOSKernel.dll.
    
    In addition, a $env:SystemDrive\DynamicsTools folder must exist and contain the
    required tools for packaging like NuGet.exe and 7za.exe.

    Copyright © 2016 Microsoft. All rights reserved.
#>
[Cmdletbinding()]
Param(
    [Parameter(Mandatory=$true, HelpMessage="The path to the build binaries.")]
    [string]$BuildBinPath,

    [Parameter(Mandatory=$true, HelpMessage="The path to the build metadata.")]
    [string]$BuildMetadataPath,

    [Parameter(Mandatory=$true, HelpMessage="The path where to produce the deployable packages.")]
    [string]$BuildPackagePath,

    [Parameter(Mandatory=$false, HelpMessage="The build number to use in the package names.")]
    [string]$BuildVersion = "1.0.0.0",

    [Parameter(Mandatory=$false, HelpMessage="The build copyright message to use in the package names.")]
    [string]$BuildCopyright = "",

    [Parameter(Mandatory=$false, HelpMessage="Do not create runtime packages.")]
    [switch]$NoRuntime,

    [Parameter(Mandatory=$false, HelpMessage="Do not create source packages.")]
    [switch]$NoSource,

    [Parameter(Mandatory=$false, HelpMessage="The full path to the file to write output to (If not specified the output will be written to the host).")]
    [string]$LogPath=$null,

    [Parameter(Mandatory=$false, HelpMessage="Comma-separated list of binary modules to excluding from packaging")]
    [string]$ExclusionList = "",

    [Parameter(Mandatory=$false, HelpMessage="Include source-controlled binary packages.")]
    [switch]$IncludeBinaries,

    [Parameter(Mandatory=$false, HelpMessage="DynamicsSDK path replacing reg value")]
    [string]$DynamicsSDKPath,

    [Parameter(Mandatory=$false, HelpMessage="BinariesPath path replacing reg value")]
    [string]$BinariesPath,

    [Parameter(Mandatory=$false, HelpMessage="MetadataPath path replacing reg value")]
    [string]$MetadataPath,

    [Parameter(Mandatory=$false, HelpMessage="WebConfigPath path replacing reg value")]
    [string]$WebConfigPath,

    [Parameter(Mandatory=$false, HelpMessage="DynamicsTools path replacing reg value")]
    [string]$DynamicsToolsPath

    
)

# Signal package generation start
$InstrumentationScript = Join-Path -Path $PSScriptRoot -ChildPath "DevALMInstrumentor.ps1"
# & $InstrumentationScript -TaskGeneratePackagesStart -DataArgument "{ `"NoRuntime`": `"$NoRuntime`", `"NoSource`": `"$NoSource`", `"ExclusionList`": `"$($ExclusionList.Length)`", `"IncludeBinaries`": `"$IncludeBinaries`" }"


# Import module for Write-Message and other common functions (Picks up $LogPath variable).
Import-Module $(Join-Path -Path $PSScriptRoot -ChildPath "DynamicsSDKCommon.psm1") -Function "Write-Message", "Get-AX7SdkDeploymentBinariesPath", "Get-AX7SdkDeploymentMetadataPath", "Get-AX7DeploymentAosWebConfigPath", "Get-AX7SdkDeploymentAosWebsiteName", "Get-AX7DeploymentAosWebConfigPath"

<#
.SYNOPSIS
    Create deployable runtime package containing the binaries for the
    specified package names.

.OUTPUTS
    System.String. Returns the full path to the package file created.
#>
function Create-DeployableRuntimePackage(
    [string[]]$PackageNames,
    [string]$OutputPath,
    [string]$DeploymentBinDir,
    [string]$BuildBinDir,
    [string]$BuildMetadataDir,
    [string]$BuildVersion,
    [string]$KernelVersion,
    [string]$BuildCopyright,
    [string]$DeploymentWebRootDir,
    [bool]$enforceVersionCheck = $false)
{
    [string]$DeployableRuntimePackagePath = $null
    if ($PackageNames -ne $null -and $PackageNames.Count -gt 0)
    {
        $CreatePackageModulePathAuxSDK = Join-Path -Path $DynamicsSDKPath -ChildPath "CreatePackageAux.psm1"
        $CreatePackageModulePath = Join-Path -Path $DeploymentBinDir -ChildPath "CreatePackageAux.psm1"

        Copy-Item $CreatePackageModulePathAuxSDK -Destination $CreatePackageModulePath -Force

        if (!(Test-Path -Path $CreatePackageModulePath -PathType Leaf))
        {
            throw "The create package module does not exist: $CreatePackageModulePath"
        }

        if (!(Test-Path -Path $OutputPath -PathType Container))
        {
            New-Item -Path $OutputPath -ItemType Container | Out-Null
        }

        Write-Message "- Importing create package module..." -Diag

        Import-Module $CreatePackageModulePath -Function "New-XppRuntimePackageAux" -Force

        # Create the individual runtime packages.
        foreach ($PackageName in $PackageNames)
        {
            $BuildPackageDrop = Join-Path -Path $BuildBinDir -ChildPath $PackageName
            Write-Message "- $($PackageName): Creating runtime package..." -Diag
            $RuntimePackagePath = New-XppRuntimePackageAux -packageName $PackageName -packageDrop $BuildPackageDrop -outputDir $OutputPath -metadataDir $BuildMetadataDir -packageVersion $KernelVersion -binDir $DeploymentBinDir -copyRight $BuildCopyright -webRoot $DeploymentWebRootDir -enforceVersionCheck $enforceVersionCheck -dynamicsToolsPath $DynamicsToolsPath
            if (Test-Path -Path $RuntimePackagePath)
            {
                Write-Message "- $($PackageName): Created $([System.IO.Path]::GetFileName($RuntimePackagePath))" -Diag
            }
            else
            {
                throw "Runtime package for $($PackageName) was not successfully created in $($OutputPath)."
            }
        }

        # Load assembly with functionality to create deployable package from the
        # individual runtime packages.
        $CreateDeployablePackagePath = Join-Path -Path $DeploymentBinDir -ChildPath "Microsoft.Dynamics.AXCreateDeployablePackageBase.dll"
        if (Test-Path -Path $CreateDeployablePackagePath -PathType Leaf)
        {
            $RuntimePackageFiles = @(Get-ChildItem -Path $OutputPath -File)
            if ($RuntimePackageFiles.Count -gt 0)
            {
                Write-Message "- Loading create deployable package assembly..." -Diag
                Add-Type -Path $CreateDeployablePackagePath

                # Create single archive with all runtime packages.
                $CombinedRuntimePackagePath = Join-Path -Path $OutputPath -ChildPath "AXCombinedRuntime_$($KernelVersion)_$($BuildVersion).zip"
                Write-Message "- Creating combined runtime package: $CombinedRuntimePackagePath" -Diag
                [Microsoft.Dynamics.AXCreateDeployablePackageBase.BuildDeployablePackages]::CreateMetadataPackage($OutputPath, $CombinedRuntimePackagePath)

                # Merge all runtime packages with installer base package.
                $DeployableBasePackagePath = Join-Path -Path $DeploymentBinDir -ChildPath "BaseMetadataDeployablePackage.zip"
                $DeployableRuntimePackagePath = Join-Path -Path $BuildPackageDir -ChildPath "AXDeployableRuntime_$($KernelVersion)_$($BuildVersion).zip"
                Write-Message "- Merging with deployable base package: $DeployableBasePackagePath" -Diag
                $DeployablePackageCreated = [Microsoft.Dynamics.AXCreateDeployablePackageBase.BuildDeployablePackages]::MergePackage($DeployableBasePackagePath, $CombinedRuntimePackagePath, $DeployableRuntimePackagePath, $true, [String]::Empty)
                if ($DeployablePackageCreated)
                {
                    Write-Message "- Deployable runtime package was successfully created: $DeployableRuntimePackagePath" -Diag
                }
                else
                {
                    throw "Failed to create deployable runtime package at: $DeployableRuntimePackagePath"
                }
            }
            else
            {
                Write-Message "No deployable runtime package will be created as no files were found in: $OutputPath" -Warning
            }
        }
        else
        {
            Write-Message "No deployable runtime package will be created as a required tool was not found: $CreateDeployablePackagePath" -Warning
        }
    }

    return $DeployableRuntimePackagePath
}

<#
.SYNOPSIS
    Create model source package containing the source for the
    specified model names.

.OUTPUTS
    System.String. Returns the full path to the package file created.
#>
function Create-ModelSourcePackage(
    [string[]]$ModelNames,
    [string]$OutputPath,
    [string]$DeploymentBinDir,
    [string]$BuildBinDir,
    [string]$DeploymentMetadataDir,
    [string]$BuildVersion,
    [string]$KernelVersion)
{
    [string]$ModelSourcePackagePath = $null

    if ($ModelNames -ne $null -and $ModelNames.Count -gt 0)
    {
        $ModelUtilPath = Join-Path -Path $DeploymentBinDir -ChildPath "ModelUtil.exe"
        $SourcePackageOutputPath = Join-Path -Path $BuildPackageDir -ChildPath "Source"
        
        if (!(Test-Path -Path $ModelUtilPath -PathType Leaf))
        {
            throw "The tool to create source packages does not exist: $ModelUtilPath"
        }

        if (!(Test-Path -Path $SourcePackageOutputPath -PathType Container))
        {
            New-Item -Path $SourcePackageOutputPath -ItemType Container | Out-Null
        }
        
        foreach ($ModelName in $ModelNames)
        {
            # TODO: Replace call to ModelUtil.exe with API calls to improve error handling.
            # Note: ModelUtil must have path to deployment metadata to be able to discover overlayering
            # of code in existing packages.
            Write-Message "- $($ModelName): Exporting model source..." -Diag
            Write-Message "- Command: $ModelUtilPath -export -metadatastorepath=`"$DeploymentMetadataDir`" -modelname=`"$ModelName`" -outputpath=`"$SourcePackageOutputPath`"" -Diag
            $ModelUtilOutput = & $ModelUtilPath -export -metadatastorepath="$DeploymentMetadataDir" -modelname="$ModelName" -outputpath="$SourcePackageOutputPath"

            # Check exit code to make sure the model export was successful.
            $ModelUtilExitCode = [int]$LASTEXITCODE

            # Log output if any.
            if ($ModelUtilOutput -and $ModelUtilOutput.Count -gt 0)
            {
                $ModelUtilOutput | % { Write-Message $_ -Diag }
            }

            Write-Message "- $($ModelName): Model export completed with exit code: $ModelUtilExitCode" -Diag
            if ($ModelUtilExitCode -ne 0)
	        {
		        throw "Error: Unexpected exit code from model export: $ModelUtilExitCode"
	        }

            # Find model export output file.
            $ModelUtilFilePattern = "^$($ModelName)\-.+\.axmodel$"
            $ModelUtilFiles = @(Get-ChildItem -Path $SourcePackageOutputPath -File | Where-Object -FilterScript { $_.Name -imatch $ModelUtilFilePattern })
            if ($ModelUtilFiles.Count -eq 0)
            {
                throw "Source package for $($ModelName) was not successfully created in $($SourcePackageOutputPath). Expected file matching pattern: $ModelUtilFilePattern"
            }
            else
            {
                if ($ModelUtilFiles.Count -gt 1)
                {
                    Write-Message "- $($ModelName): Found $($ModelUtilFiles.Count) exported models matching $($ModelUtilFilePattern). Selecting first." -Diag
                }
                $SourcePackagePath = $ModelUtilFiles[0].FullName
                Write-Message "- $($ModelName): Created $([System.IO.Path]::GetFileName($SourcePackagePath))" -Diag
            }
        }
        
        $SevenZipPath = ""
    
        if ([String]::IsNullOrEmpty($DynamicsToolsPath))
        {
            $SevenZipPath = Join-Path -Path $($env:SystemDrive) -ChildPath "DynamicsTools\7za.exe"
        }
        else
        {
            $SevenZipPath = Join-Path -Path $DynamicsToolsPath -ChildPath "7za.exe"
        }

        if (Test-Path -Path $SevenZipPath -PathType Leaf)
        {
            $SourcePackageFilePattern = "*.axmodel"
            $SourcePackageFiles = @(Get-ChildItem -Path $SourcePackageOutputPath -File -Filter $SourcePackageFilePattern)
            if ($SourcePackageFiles.Count -gt 0)
            {
                $ModelSourcePackagePath = Join-Path -Path $BuildPackageDir -ChildPath "AXModelSource_$($KernelVersion)_$($BuildVersion).zip"
                Write-Message "- Creating model source package: $ModelSourcePackagePath" -Diag
                
                $SevenZipOutput = & $SevenZipPath a -y -mx3 `"$($ModelSourcePackagePath)`" `"$($SourcePackageOutputPath)\*.axmodel`"

                # Check exit code to make sure the compression was successful.
                $SevenZipExitCode = [int]$LASTEXITCODE

                # Log output if any.
                if ($SevenZipOutput -and $SevenZipOutput.Count -gt 0)
                {
                    $SevenZipOutput | % { Write-Message $_ -Diag }
                }

                Write-Message "- Deployable model package compression completed with exit code: $SevenZipExitCode" -Diag
                if ($SevenZipExitCode -ne 0)
	            {
		            throw "Error: Unexpected exit code from compression tool: $SevenZipExitCode"
	            }

                if (Test-Path -Path $ModelSourcePackagePath -PathType Leaf)
                {
                    Write-Message "- Deployable model package was successfully created: $ModelSourcePackagePath" -Diag
                }
                else
                {
                    throw "Failed to create model source package at: $ModelSourcePackagePath"
                }
            }
            else
            {
                Write-Message "No model source package will be created as no files matching $($SourcePackageFilePattern) were found in: $SourcePackageOutputPath" -Warning
            }
        }
        else
        {
            Write-Message "No model source package will be created as a required tool was not found: $SevenZipPath" -Warning
        }
    }

    return $ModelSourcePackagePath
}

<#
.SYNOPSIS
    Get the Dynamics AX 7.0 deployment's kernel version.

.NOTES
    Will return the default version if the AOSKernel.dll's product version
    cannot be found from the deployment binaries folder.

.OUTPUTS
    System.String. The deployment's kernel version.
#>
function Get-AX7DeploymentKernelVersion([string]$DeploymentBinDir, [string]$DefaultVersion = "7.0.0.0")
{
    [string]$KernelVersion = $DefaultVersion

    if (Test-Path -Path $DeploymentBinDir -PathType Container)
    {
        $KernelPath = Join-Path -Path $DeploymentBinDir -ChildPath "AOSKernel.dll"
        if (Test-Path -Path $KernelPath -PathType Leaf)
        {
            $KernelFile = Get-Item -Path $KernelPath
            if ($KernelFile -and $KernelFile.VersionInfo -and $KernelFile.VersionInfo.FileVersion)
            {
                $KernelVersion = $KernelFile.VersionInfo.FileVersion
            }
        }
    }

    return $KernelVersion
}

[int]$ExitCode = 0
try
{
    Write-Message "Generating deployable packages for build in: $BuildBinPath"

    if ([String]::IsNullOrEmpty($BuildBinPath))
    {
        throw "No valid path is specified in BuildBinPath parameter."
    }

    if (!(Test-Path -Path $BuildBinPath -PathType Container))
    {
        throw "Specified build binaries folder path does not exist: $BuildBinPath"
    }

    if ([String]::IsNullOrEmpty($BuildMetadataPath))
    {
        throw "No valid path is specified in BuildMetadataPath parameter."
    }

    if (!(Test-Path -Path $BuildMetadataPath -PathType Container))
    {
        throw "Specified build metadata folder path does not exist: $BuildMetadataPath"
    }

    if ([String]::IsNullOrEmpty($BuildPackagePath))
    {
        throw "No valid path is specified in BuildPackagePath parameter."
    }

    if (Test-Path -Path $BuildPackagePath -PathType Container)
    {
        Write-Message "- Removing existing files in package path: $BuildPackagePath"
        Remove-Item -Path $BuildPackagePath -Include *.* -Recurse -Force | Out-Null
    }
    else
    {
        New-Item -Path $BuildPackagePath -ItemType Container | Out-Null
    }

    # Resolve specified paths to full paths.
    $BuildMetadataDir = Resolve-Path -Path $BuildMetadataPath
    $BuildBinDir = Resolve-Path -Path $BuildBinPath
    $BuildPackageDir = Resolve-Path -Path $BuildPackagePath
    
    # Get the deployment's binaries directory from Dynamics SDK registry.
    $DeploymentBinDir = ""
    
    if ([String]::IsNullOrEmpty($BinariesPath))
    {
        $DeploymentBinDir = Get-AX7SdkDeploymentBinariesPath
    }
    else
    {
        $DeploymentBinDir = $BinariesPath
    }

    # Get the deployment's metadata directory from Dynamics SDK registry.
    $DeploymentMetadataDir = ""
    
    if ([String]::IsNullOrEmpty($MetadataPath))
    {
        $DeploymentMetadataDir = Get-AX7SdkDeploymentMetadataPath
    }
    else
    {
        $DeploymentMetadataDir = $MetadataPath
    }
   
    # Get deployment kernel product version to use for package names.
    # This is used to indicate the kernel version on which the metadata was produced.
    # It will be combined with the $BuildVersion in the deployable package name.
    $KernelVersion = Get-AX7DeploymentKernelVersion -DeploymentBinDir $DeploymentBinDir -DefaultVersion "7.0.0.0"
    
    # Create deployable runtime package.
    if (!$NoRuntime)
    {
        $productInfoPath = ""

        if ([String]::IsNullOrEmpty($WebConfigPath))
        {
            $productInfoPath = Split-Path (Get-AX7DeploymentAosWebConfigPath)
        }
        else
        {
            $productInfoPath = Split-Path ($WebConfigPath)
        }

        $productInfoPath = Join-Path -Path $productInfoPath -ChildPath "bin"

        $applicationInfoPath = Join-Path -Path $productInfoPath -ChildPath "ProductInfo/Microsoft.Dynamics.BusinessPlatform.ProductInformation.Application.dll"
        $platformInfoPath = Join-Path -Path $productInfoPath -ChildPath "ProductInfo/Microsoft.Dynamics.BusinessPlatform.ProductInformation.Platform.dll"

        $MetadataAssemblyPath = Join-Path -Path $DeploymentBinDir -Childpath "Microsoft.Dynamics.AX.Metadata.Core.dll"
        if (!(Test-Path -Path $MetadataAssemblyPath))
        {
            throw "Metadata core assembly does not exist: $MetadataAssemblyPath"
        }
        Add-Type -Path $MetadataAssemblyPath
        $PlatformPackages = [Microsoft.Dynamics.AX.Metadata.Core.CoreHelper]::GetPackagesNames($platformInfoPath)

        Add-Type -Path (Join-Path -Path $productInfoPath -ChildPath "Microsoft.Dynamics.BusinessPlatform.ProductInformation.Provider.dll")
        $provider = [Microsoft.Dynamics.BusinessPlatform.ProductInformation.Provider.ProductInfoProvider]::Provider
        [System.Version]$appVersion = $provider.ApplicationBuildVersion
        [System.Version]$sealedVersion = "8.1.0.0"
        [System.Version]$directoryInAppVersion = "7.1.0.0"
        if ($appVersion -ge $sealedVersion)
        {
            $ApplicationPackages = [Microsoft.Dynamics.AX.Metadata.Core.CoreHelper]::GetPackagesNames($applicationInfoPath)
            $SealedApp = $true
        }
        else
        {
            if ($appVersion -ge $directoryInAppVersion)
            {
                # Filter out Directory package if app version is higher than RTW and lower than 8.1
                $PlatformPackages = $PlatformPackages | Where-Object { $_ -ne "Directory" }
            }

            $ApplicationPackages = @()
            $SealedApp = $false
        }

        $BuildPackageNames = @()
            
        $Exclusions = $ExclusionList.Split(",")
        # Strip any whitespaces that people may add around the comma
        for ($i = 0; $i -lt $Exclusions.Length; $i++)
        {
            $Exclusions[$i] = $Exclusions[$i].Trim()
        }

        # If enabled, copy existing runtime binaries to output folder to be included in runtime package
        if ($IncludeBinaries)
        {
            # Discover packages in source folder that are binary only.
            Write-Message "Finding source-controlled runtime packages in: $BuildMetadataDir"
            $BinaryModuleDirectories = @(Get-ChildItem -Path $BuildMetadataDir -Directory)
            foreach ($BinaryModuleDirectory in $BinaryModuleDirectories)
            {
                $PackageName = $BinaryModuleDirectory.Name
                $BinaryModuleBinPath = Join-Path -Path $BinaryModuleDirectory.FullName -ChildPath "Bin\Dynamics.AX.$PackageName.dll"
                $BinaryModuleDescriptorPath = Join-Path -Path $BinaryModuleDirectory.FullName -ChildPath "Descriptor"

                # Binary-only packages have a corresponding DLL and no descriptor files
                if ((Test-Path -Path $BinaryModuleBinPath -PathType Leaf) -and -not (Test-Path -Path "$BinaryModuleDescriptorPath\*.xml" -PathType Leaf))
                {
                    if ($Exclusions -icontains $PackageName)
                    {
                        Write-Message "- Excluding binary package: $PackageName"
                    }
                    elseif ($PlatformPackages -icontains $PackageName)
                    {
                        Write-Message "- '$PackageName' will be excluded from the deployable package. Binaries for platform packages should not be in source control or included in a custom deployable package" -Error
                    }
                    elseif ($ApplicationPackages -icontains $PackageName)
                    {
                        Write-Message "- '$PackageName' will be excluded from the deployable package. Binaries for application version 8.1 and above should not be in source control or included in a custom deployable package" -Error
                    }
                    else
                    {
                        Write-Message "- Copying binary package $BinaryModuleDirectory to $BuildBinDir ..." -Diag
                        Copy-Item -Path $BinaryModuleDirectory.FullName -Destination $BuildBinDir -Recurse -Force
                    }
                }
            }
        }

        # Discover package names to generate deployable runtime packages for.
        Write-Message "Finding package names in: $BuildBinDir"
        $BuildModuleDirectories = @(Get-ChildItem -Path $BuildBinDir -Directory)
        foreach ($BuildModuleDirectory in $BuildModuleDirectories)
        {
            $PackageName = $BuildModuleDirectory.Name
            if ($Exclusions -icontains $PackageName)
            {
                Write-Message "- Excluding package name: $PackageName"
            }
            elseif ($PlatformPackages -icontains $PackageName)
            {
                Write-Message "- '$PackageName' will be excluded from the deployable package. Source code for platform packages should not be in source control or included in a custom deployable package" -Error
            }
            elseif ($ApplicationPackages -icontains $PackageName)
            {
                Write-Message "- '$PackageName' will be excluded from the deployable package. Source code for application version 8.1 and above should not be in source control or included in a custom deployable package" -Error
            }
            else
            {            
                Write-Message "- Found package name: $PackageName"
                $BuildPackageNames += $PackageName
            }
        }
        Write-Message "Found $($BuildPackageNames.Count) package names."
            
        if ($BuildPackageNames.Count -gt 0)
        {
            # Get the deployment's web site name from Dynamics SDK registry.
            $WebSiteName = Get-AX7SdkDeploymentAosWebsiteName

            # Get the deployment's web root directory from Dynamics SDK registry (directory of web.config).
            $DeploymentWebRootDir = $null
            $DeploymentWebConfigPath = ""

            if ([String]::IsNullOrEmpty($WebConfigPath))
            {
                $DeploymentWebConfigPath = Get-AX7DeploymentAosWebConfigPath -WebSiteName $WebSiteName
            }
            else
            {
                $DeploymentWebConfigPath = $WebConfigPath
            }

            if ($DeploymentWebConfigPath)
            {
                $DeploymentWebRootDir = Split-Path -Path $DeploymentWebConfigPath -Parent
            }
            if (!$DeploymentWebRootDir)
            {
                throw "The deployment web root directory could not be found."
            }
            if (!(Test-Path -Path $DeploymentWebRootDir -PathType Container))
            {
                throw "The deployment web root directory does not exist: $DeploymentWebRootDir"
            }
            
            $OutputPath = Join-Path -Path $BuildPackageDir -ChildPath "Runtime"
            Write-Message "Creating deployable runtime package..."
            $DeployablePackagePath = Create-DeployableRuntimePackage -PackageNames $BuildPackageNames -OutputPath $OutputPath -DeploymentBinDir $DeploymentBinDir -BuildBinDir $BuildBinDir -BuildMetadataDir $BuildMetadataDir -BuildVersion $BuildVersion -KernelVersion $KernelVersion -BuildCopyright $BuildCopyright -DeploymentWebRootDir $DeploymentWebRootDir -enforceVersionCheck $SealedApp
            Write-Message "Created deployable runtime package: $DeployablePackagePath"
        }
        else
        {
            Write-Message "No package names could be found. No deployable runtime package will be created." -Warning
        }
    }
    else
    {
        Write-Message "- NoRuntime switch specified. Skipping deployable runtime package creation." -Diag
    }

    # Create model source package.
    if (!$NoSource)
    {
        $BuildModelNames = @()
        
        # Discover model names to generate model source packages for.
        Write-Message "Finding model names in: $BuildMetadataDir"
        $BuildModuleDirectories = @(Get-ChildItem -Path $BuildMetadataDir -Directory)
        foreach ($BuildModuleDirectory in $BuildModuleDirectories)
        {
            # Get the model names from the descriptor file names.
            $BuildDescriptorPath = Join-Path -Path $($BuildModuleDirectory.FullName) -ChildPath "Descriptor"
            if (Test-Path -Path $BuildDescriptorPath -PathType Container)
            {
                $DescriptorFiles = @(Get-ChildItem -Path $BuildDescriptorPath -File -Filter "*.xml")
                if ($DescriptorFiles.Count -gt 0)
                {
                    foreach ($DescriptorFile in $DescriptorFiles)
                    {
                        $ModelName = $DescriptorFile.BaseName
                        $modelPath = Join-Path -Path $($BuildModuleDirectory.FullName) -ChildPath $ModelName
                        
                        # Make sure it's not just a descriptor file without a model file
                        # This sometimes is done to force a rebuild of a standard package, for example AppSuite to enable CoC
                        if (Test-Path -Path $modelPath)
                        {
                            [xml]$descriptorXML = Get-Content -Path $DescriptorFile.FullName
                            $node = $descriptorXML.AxModelInfo.SelectSingleNode("Disabled")
                            # Make sure the model isn't disabled by checking if Disabled node isn't present or not set to true
                            if (($node -eq $null) -or ($node.InnerText -ine [bool]::TrueString))
                            {
                                Write-Message "- Found model name: $ModelName"
                                $BuildModelNames += $ModelName
                            }
                            else
                            {    
                                Write-Message "- Skipping disabled model: $ModelName"
                            }
                        }
                        else
                        {    
                            Write-Message "- Skipping descriptor-only model: $ModelName"
                        }
                    }
                }
                else
                {
                    Write-Message "No descriptor files found in: $($BuildDescriptorPath)" -Warning
                }
            }
            else
            {
                Write-Message "No descriptor folder found at: $($BuildDescriptorPath)" -Warning
            }
        }
        Write-Message "Found $($BuildModelNames.Count) model names."
        
        if ($BuildModelNames.Count -gt 0)
        {
            $OutputPath = Join-Path -Path $BuildPackageDir -ChildPath "Source"
            Write-Message "Creating model source package..."
            $DeployablePackagePath = Create-ModelSourcePackage -ModelNames $BuildModelNames -OutputPath $OutputPath -DeploymentBinDir $DeploymentBinDir -BuildBinDir $BuildBinDir -DeploymentMetadataDir $DeploymentMetadataDir -BuildVersion $BuildVersion -KernelVersion $KernelVersion
            Write-Message "Created model source package: $DeployablePackagePath"
        }
        else
        {
            Write-Message "No model names could be found. No model source package will be created." -Warning
        }
    }
    else
    {
        Write-Message "- NoSource switch specified. Skipping model source package creation." -Diag
    }

    Write-Message "Generating deployable packages complete."

    # Signal package generation end
    # & $InstrumentationScript -TaskGeneratePackagesStop
}
catch [System.Exception]
{
    Write-Message "- Exception thrown at $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())$([Environment]::NewLine)$($_.Exception.ToString())" -Diag
    Write-Message "Error generating deployable packages: $($_)" -Error
    $ExitCode = -1

    # Log exception in telemetry
    # & $InstrumentationScript -ExceptionMarker -ExceptionString ($_.Exception.ToString())
}
Write-Message "Script completed with exit code: $ExitCode"
Exit $ExitCode
# SIG # Begin signature block
# MIIjnwYJKoZIhvcNAQcCoIIjkDCCI4wCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAO5WM8hCRDZ3VR
# CQHYMZMjFJJoc/+F0uUYDgft58y47KCCDYEwggX/MIID56ADAgECAhMzAAAB32vw
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
# BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgc9Ka75RX
# kNKO4UuGpawwpoP/Zrqnve7m/XuWsP/tiRcwQgYKKwYBBAGCNwIBDDE0MDKgFIAS
# AE0AaQBjAHIAbwBzAG8AZgB0oRqAGGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbTAN
# BgkqhkiG9w0BAQEFAASCAQCeHSks8BFL0FNjP16dQEoLiVNAKNh5OWUBPxhMnZCL
# NNRwyQcmd+z550iF8zD6srkYwVaxnhCqe8KsTTVso4dFNiagCUxnAXShqFMyqr8+
# 6/KtZKKKpGADTh/VCixJ2P+evEWfbL8lIr0s2MG8qxI6CH+hhr8YdMa+Ywnrp7Yf
# PCTB294SwfX09XqL3+NsqeAye8yj2jRknNvOSdDxGoySGo8NqaUpOZXItUve4uf1
# 1r9Ftqm5exCztYgp1sDldk5EIRhJXbiqTLUnzj11iu8Rmmsg3yAz5gaiReIg2KG9
# dniHNgDbPR1K87Tfw73ggHQtheGh+L9gAEL6xDFp6Q/JoYIS/jCCEvoGCisGAQQB
# gjcDAwExghLqMIIS5gYJKoZIhvcNAQcCoIIS1zCCEtMCAQMxDzANBglghkgBZQME
# AgEFADCCAVkGCyqGSIb3DQEJEAEEoIIBSASCAUQwggFAAgEBBgorBgEEAYRZCgMB
# MDEwDQYJYIZIAWUDBAIBBQAEIPlLvH6pNetP7h1NCH+Y4+UU6y1mtEFV+L009nYi
# ISX1AgZgPN+tEj8YEzIwMjEwMzAzMDMxMDAwLjcyN1owBIACAfSggdikgdUwgdIx
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
# AQQwLwYJKoZIhvcNAQkEMSIEIHsLGS6RBFOSyPcXjLXAqUxOZV5OaxNAC9IwDnOi
# 9pg3MIH6BgsqhkiG9w0BCRACLzGB6jCB5zCB5DCBvQQgHVl+r8CeBJ0iyX/aGZD2
# YbQ7gk+U7N7BQiTDKAYSHBAwgZgwgYCkfjB8MQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQ
# Q0EgMjAxMAITMwAAATdBj0PnWltvpwAAAAABNzAiBCAi65JPa6/l/RvHv8jkVUIE
# Laur+CfHdrhP7d4NaYF+fTANBgkqhkiG9w0BAQsFAASCAQCix0dZv6Cw1Jfgwtgq
# MIkYa24suqkpCGWhd9V1X3X0wjSS3OyzKYHg8hEWRszjd+oi+g5C5QFbEJdKCIyW
# 3msdMjMIDq9GzEnoNrksYhuxHo+K++z/wt4xXZdgQHvCIs3lIhJOq/8DhPHrRlG9
# fjQoBItnd4WlhmRrLI7gSOnow4BMhhjscaHJHwTOrtT8mRiyZOehpsN3y+uQbbp9
# tbsFOwEuY5Z3aes6cnGnnKIM2raB3qDZcJntMlEUDN8fHWymaeLoaQGg2TiobLff
# JkfsJMW11mvIpD2b4uOshYTK2fzSqyVnlwxtGvpH1UeJMweyAhHC3h8FEqw1Liqo
# F8Or
# SIG # End signature block
