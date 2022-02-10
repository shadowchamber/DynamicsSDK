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

    [Parameter(Mandatory=$false, HelpMessage="WebConfigPath path")]
    [string]$WebConfigPath,

    [Parameter(Mandatory=$false, HelpMessage="DynamicsTools path")]
    [string]$DynamicsToolsPath,

    [Parameter(Mandatory=$false, HelpMessage="Package file path")]
    [string]$PackageFilePath

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
	    Rename-Item -Path $DeployablePackagePath -NewName $PackageFilePath
	    Write-Message "Created model source package: $DeployablePackagePath $PackageFilePath"
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
