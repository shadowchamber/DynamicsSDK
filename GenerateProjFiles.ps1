<#
.SYNOPSIS
    Generate project files required to build the Dynamics AX modules.

.DESCRIPTION
    This script is intended for use in the Dynamics AX Development environment
    to automate the build process.

.NOTES
    When running through automation, use the -LogPath option to redirect
    output to a log file rather than the console. When the console output is
    used a -Verbose option can be added to get more detailed output.

    Copyright © 2016 Microsoft. All rights reserved.
#>
[Cmdletbinding()]
Param(
    [Parameter(Mandatory=$true, HelpMessage="The path to the metadata of the modules build.")]
    [string]$MetadataPath,

    [Parameter(Mandatory=$false, HelpMessage="The full path to the file to write output to (If not specified the output will be written to the host).")]
    [string]$LogPath=$null,

    [Parameter(Mandatory=$false, HelpMessage="The full path to the file that will be created in case an error occurs.")]
    [string]$ErrorLogPath=$(Join-Path -Path $MetadataPath -ChildPath "GenerateProjErrors.log"),

    [Parameter(Mandatory=$false, HelpMessage="The name of the XML file that defines a custom order of the modules and projects to build (The file must exist in the Projects folder).")]
    [string]$ProjectMetadataDependencyXml=$null,

    [Parameter(Mandatory=$false, HelpMessage="The absolute path of the folder where the MSBuild binaries that are currently being used")]
    [string]$MSbuildBinPath = $null
)

# Signal project generation start
$InstrumentationScript = Join-Path -Path $PSScriptRoot -ChildPath "DevALMInstrumentor.ps1"
& $InstrumentationScript -TaskGenerateProjFilesStart -DataArgument "{ `"DependencyXML`": `"$($ProjectMetadataDependencyXml.Length)`" }"

# Import module for Write-Message and other common functions (Picks up $LogPath variable).
Import-Module $(Join-Path -Path $PSScriptRoot -ChildPath "DynamicsSDKCommon.psm1") -Function "Write-Message", "Set-AX7SdkRegistryValues", "Get-AX7SdkDeploymentBinariesPath", "Get-AX7SdkDeploymentMetadataPath"

<#
.SYNOPSIS
    Create and return a metadata provider for the specified path.
.NOTES
    This function Will throw an exception if it is unable to created the metadata provider.
#>
function Get-MetadataProvider([string]$Path, [string[]]$RuntimePackages)
{
    $MetadataProvider = $null

    Write-Message "- Creating disk provider configuration for metadata path: $Path" -Diag
    $DiskProviderConfig = New-Object Microsoft.Dynamics.AX.Metadata.Storage.DiskProvider.DiskProviderConfiguration
    if ($DiskProviderConfig -ne $null)
    {
        $DiskProviderConfig.MetadataPath = $Path
        $DiskProviderConfig.ValidateExistence = $true
    
        Write-Message "- Creating metadata provider factory..." -Diag
        $MetadataProviderFactory = New-Object Microsoft.Dynamics.AX.Metadata.Storage.MetadataProviderFactory
        if ($MetadataProviderFactory -ne $null)
        {
            $RuntimeModelManifest = $null
            if ($RuntimePackages -and $RuntimePackages.Count -gt 0)
            {
                Write-Message "- Creating runtime provider configuration for metadata path: $Path" -Diag
                $RuntimeProviderConfig = New-Object Microsoft.Dynamics.AX.Metadata.Storage.Runtime.RuntimeProviderConfiguration -ArgumentList $Path, $false, $false, $RuntimePackages
                if ($RuntimeProviderConfig -ne $null)
                {
                    Write-Message "- Creating runtime metadata provider..." -Diag
                    $RuntimeMetadataProvider = $MetadataProviderFactory.CreateRuntimeProvider($RuntimeProviderConfig)
                    if ($RuntimeMetadataProvider -ne $null)
                    {
                        Write-Message "- Created runtime metata provider: $($RuntimeMetadataProvider.GetType().FullName)" -Diag
                        $RuntimeModelManifest = $RuntimeMetadataProvider.ModelManifest
                    }
                    else
                    {
                        throw "Failed to create metadata provider from runtime provider configuration with metadata path: $($Path)."
                    }
                }
                else
                {
                    throw "Failed to create instance of Microsoft.Dynamics.AX.Metadata.Storage.Runtime.RuntimeProviderConfiguration."
                }
            }

            if ($RuntimeModelManifest)
            {    
                Write-Message "- Creating metadata provider with runtime model manifest..." -Diag
                $MetadataProvider = $MetadataProviderFactory.CreateDiskProvider($DiskProviderConfig, $RuntimeModelManifest)
            }
            else
            {
                Write-Message "- Creating metadata provider..." -Diag
                $MetadataProvider = $MetadataProviderFactory.CreateDiskProvider($DiskProviderConfig)
            }

            if ($MetadataProvider -ne $null)
            {
                Write-Message "- Created metadata provider: $($MetadataProvider.GetType().FullName)" -Diag
            }
            else
            {
                throw "Failed to create metadata provider from disk provider configuration with metadata path: $($Path)."
            }
        }
        else
        {
            throw "Failed to create instance of Microsoft.Dynamics.AX.Metadata.Storage.MetadataProviderFactory."
        }
    }
    else
    {
        throw "Failed to create instance of Microsoft.Dynamics.AX.Metadata.Storage.DiskProvider.DiskProviderConfiguration."
    }
    return $MetadataProvider
}

<#
.SYNOPSIS
    Generate the default proj file to build all X++ modules found in the version control system.
#>
function GenerateDefaultBuildMetadataProj($ModelsInfo, $ModulesAndModels, [string]$MetadataPath, [string]$DeploymentMetadataPath, [string[]]$RuntimePackages)
{
    # If a Version.txt file exists, copy it to the deployment's metadata directory.
    $VersionSourcePath = Join-Path -Path $MetadataPath -ChildPath "Version.txt"
    if (Test-Path -Path $VersionSourcePath -PathType Leaf -ErrorAction SilentlyContinue)
    {
        Write-Message "- Copying $VersionSourcePath to $DeploymentMetadataPath ..." -Diag
        Copy-Item -Path $VersionSourcePath -Destination $DeploymentMetadataPath -Force
    }
    
    # Copy the source code and descriptor for each model to the deployment metadata directory.
    foreach ($PackageName in $ModulesAndModels.Keys)
    {
        $TargetPackagePath = Join-Path -Path $DeploymentMetadataPath -ChildPath $PackageName
            
        # Create folder for package in deployment metadata directory.
        if (!(Test-Path -Path $TargetPackagePath))
        {
            Write-Message "- Creating directory: $TargetPackagePath" -Diag
            $NewDirectory = New-Item -Path $TargetPackagePath -ItemType Directory -Force
        }
        else
        {
            Write-Message "Package folder already exists in deployment: $($TargetPackagePath)" -Warning
        }
            
        # Copy the package source code to the deployment metadata directory.
        $SourcePackagePath = Join-Path -Path $MetadataPath -ChildPath $PackageName
        Write-Message "- Copying $SourcePackagePath to $DeploymentMetadataPath ..." -Diag
        Copy-Item -Path $SourcePackagePath -Destination $DeploymentMetadataPath -Recurse -Force
    }

    # Copy the referenced runtime packages to the deployment metadata directory.
    foreach ($RuntimePackage in $RuntimePackages)
    {
        $TargetRuntimePackagePath = Join-Path -Path $DeploymentMetadataPath -ChildPath $RuntimePackage
            
        # Create folder for package in deployment metadata directory.
        if (!(Test-Path -Path $TargetRuntimePackagePath))
        {
            Write-Message "- Creating directory: $TargetRuntimePackagePath" -Diag
            $NewDirectory = New-Item -Path $TargetRuntimePackagePath -ItemType Directory -Force
            
            # Create customization file to track that this package was added by the build process.
            $CustomizationFile = Join-Path -Path $TargetRuntimePackagePath -ChildPath "Customization.txt"
            "Runtime-only customization added by build process on $([DateTime]::Now)." | Out-File -FilePath $CustomizationFile -Force
        }
        else
        {
            Write-Message "Package folder already exists in deployment: $($TargetRuntimePackagePath)" -Warning
        }
            
        # Copy runtime package to the deployment metadata directory if it was part of VSTS code.
        $SourceRuntimePackagePath = Join-Path -Path $MetadataPath -ChildPath $RuntimePackage
        if (Test-Path -Path $SourceRuntimePackagePath)
        {
            Write-Message "- Copying $SourceRuntimePackagePath to $DeploymentMetadataPath ..." -Diag
            Copy-Item -Path $SourceRuntimePackagePath -Destination $DeploymentMetadataPath -Recurse -Force
        }
    }

    # Get the metadata provider for the deployment directory with runtime packages.
    $MetadataProvider = Get-MetadataProvider -Path $DeploymentMetadataPath -RuntimePackages $RuntimePackages
    if ($MetadataProvider -ne $null -and $MetadataProvider.Count -gt 0)
    {
        # ModulesAndModels list is not in the correct order of module dependency. Based on the models, find out the ordered list of dependent modules.
        if ($MetadataProvider[0].ModelInfoProvider.PSObject.Methods.Name -icontains "ListModulesInDependencyOrder")
        {
            # Used for platform update 3 and later
            $OrderedListOfDependentModules = $MetadataProvider[0].ModelInfoProvider.ListModulesInDependencyOrder()
        }
        else
        {
            $OrderedListOfDependentModules = $MetadataProvider[0].ModelInfoProvider.ListModules($ModelsInfo)
        }

        # This ordered list contains all the modules that the models have dependency on (not just the ones that require building). Filter this list by comparing with the modules in ModulesAndModels.
        $OrderedListOfModulesToBuild = $OrderedListOfDependentModules.Name | Where-Object {$ModulesAndModels.Keys -icontains "$_"}

        $i = 0
        foreach ($ModuleName in $OrderedListOfModulesToBuild)
        {
            $ModelNames = $ModulesAndModels[$ModuleName]
          
            $i += 1
            $ModulesToBuild += "<ModuleToBuild$i>$ModuleName</ModuleToBuild$i>"
            $ModelsToBuild += "<ModelsToBuild$i>$ModelNames</ModelsToBuild$i>"

            Write-Message "- Adding build task for the $($ModuleName) package." -Diag
            $BuildMetadataProjects += @"
<MSBuild Projects="@(ProjectToBuildMetadata)" ContinueOnError="ErrorAndStop" StopOnFirstFailure="true" Properties="ModuleToBuild=`$(ModuleToBuild$i);ModelsToBuild=`$(ModelsToBuild$i)"/>
"@
        }
    
        # Creating the orchestrating proj file.
        $Metadata_Project_Build_Path = (Get-Item -Path $MetadataPath).Parent.FullName
        $Metadata_Project_Build_Project = Join-Path -Path $Metadata_Project_Build_Path -ChildPath "Metadata_Project_Build.proj"
        Write-Message "- Creating build project: $Metadata_Project_Build_Project" -Diag

        $Metadata_Project_Build = New-Item -Path $Metadata_Project_Build_Project -Type File -Force -Value @"
<?xml version="1.0" encoding="utf-8"?>
<Project xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
    <ItemGroup>
        <ProjectToBuildMetadata Include="`$(registry:HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Dynamics\AX\7.0\SDK@DynamicsSDK)\Metadata\BuildMetadata.proj"/>     
    </ItemGroup>
    <PropertyGroup>
        $ModulesToBuild
        $ModelsToBuild
    </PropertyGroup>
    <Target Name="BuildModules">
        $BuildMetadataProjects
    </Target>    
</Project>
"@
    }
    else
    {
        throw "Failed to create metadata provider from metadata path: $DeploymentMetadataPath"
    }
}

<#
.SYNOPSIS
    Generate a custom proj file to build all projects and X++ modules specified in the dependency XML.
#>
function GenerateCustomBuildMetadataProj([string]$DependencyXmlFileName, $ModelsInfo, $ModulesAndModels, [string]$MetadataPath, [string]$DeploymentMetadataPath, [string[]]$RuntimePackages)
{
    $SrcPath = Split-Path -Path $MetadataPath
    $ProjectsPath = Join-Path -Path $SrcPath -ChildPath "Projects"
    $DependencyXmlPath = Join-Path -Path $ProjectsPath -ChildPath $DependencyXmlFileName
    [xml]$DependencyXml = Get-Content -Path $DependencyXmlPath
    if ($DependencyXml -eq $null)
    {
        throw "The dependency XML file could not be loaded from: $DependencyXmlPath"
    }

    $Projects = $DependencyXml.SelectNodes("/Projects/Project")
    $ModulesToBuild = @()
    $ModelsToBuild = @()
    $BuildMetadataProjects = @()
    $ReferencePathItemGroup = @()
    $ReferencePathProp = @()
    $DestinationPathItemGroup = @()
    $DestinationPathProp = @()
    $ModuleIndex = 0
    $ProjectIndex = 0  # Project build task index.

    foreach ($Project in $Projects)
    {
        $Type = $Project.SelectSingleNode("Type").InnerText
        $Name = $Project.SelectSingleNode("Name").InnerText

        # Generate the MSBuild task to build the projects.
        if ($Type -eq "Project")
        {
            $ProjectIndex += 1
            $ProjectPath = Join-Path -Path $ProjectsPath -ChildPath $Name
            Write-Message "- Project to build: $ProjectPath" -Diag
                        
            $ReferencedByModules = $Project.SelectNodes("ReferencedByModules/Module")
            if ($ReferencedByModules.Count -gt 0)
            {
                $ModulesString = [string]::Join(",", $($ReferencedByModules | Select-Object -ExpandProperty "InnerText"))
                Write-Message "- Project is referenced by: $ModulesString" -Diag
            }
            else
            {
                Write-Message "- Project is not referenced by any modules." -Diag
            }

            $ReferencesModules = $Project.SelectNodes("ReferencesModules/Module")
            if ($ReferencesModules.Count -gt 0)
            {
                $ModulesString = [string]::Join(",", $($ReferencesModules | Select-Object -ExpandProperty "InnerText"))
                Write-Message "- Project is referencing: $ModulesString" -Diag
            }
            else
            {
                Write-Message "- Project is not referencing any modules." -Diag
            }
                        
            # Find all the X++ modules that the project references and create AdditionalReferences for the msbuild task.
            if ($ReferencesModules.Count -gt 0)
            {
                # Add reference to main deployment binaries directory.
                $ReferencePath = Join-Path -Path $DeploymentMetadataPath -ChildPath "bin"
                Write-Message "- Adding reference path: $ReferencePath" -Diag
                # Add to reference path item group.
                $ReferencePathItemGroup += "<ReferencePath$($ProjectIndex) Include=`"$($ReferencePath)`" />"

                # Add reference to binaries directory of each module this project references.
                foreach ($ModuleName in $ReferencesModules)
                {
                    $ModulePath = Join-Path -Path $DeploymentMetadataPath -ChildPath $($ModuleName.InnerText)
                    $ModuleBinPath = Join-Path -Path $ModulePath -ChildPath "bin"
                    Write-Message "- Adding reference path: $ModuleBinPath" -Diag
                    # Add to reference path item group.
                    $ReferencePathItemGroup += "<ReferencePath$($ProjectIndex) Include=`"$($ModuleBinPath)`" />"
                }
                            
                # Add to reference path property.
                $ReferencePathProp += "<ReferencePathsProp$($ProjectIndex)>`@(ReferencePath$($ProjectIndex))</ReferencePathsProp$($ProjectIndex)>"
            }

            # Find all the X++ modules that has a reference to this project and create a list of directorys that the output of the project will be copied to.
            if ($ReferencedByModules.Count -gt 0)
            {
                foreach ($ModuleName in $ReferencedByModules)
                {
                    $ModulePath = Join-Path -Path $DeploymentMetadataPath -ChildPath $($ModuleName.InnerText)
                    if (!(Test-Path -Path $ModulePath))
                    {
                        Write-Message "- Creating directory: $ModulePath" -Diag
                        $NewDirectory = New-Item -Path $ModulePath -ItemType Directory -Force
                    }

                    $ModuleBinPath = Join-Path -Path $ModulePath -ChildPath "bin"
                    if (!(Test-Path -Path $ModuleBinPath))
                    {
                        Write-Message "- Creating directory: $ModuleBinPath" -Diag
                        $NewDirectory = New-Item -Path $ModuleBinPath -ItemType Directory -Force
                    }

                    Write-Message "- Output will be copied to: $ModuleBinPath" -Diag

                    # Add to destination path item group.
                    $DestinationPathItemGroup += "<DestinationPath$($ProjectIndex) Include=`"$($ModuleBinPath)`" />"
                }

                # Add to destination path property.
                $DestinationPathProp += "<DestinationPathsProp$($ProjectIndex)>`@(DestinationPath$($ProjectIndex))</DestinationPathsProp$($ProjectIndex)>"
            }

            Write-Message "- Creating the MSBuild task to build the project." -Diag
            $BuildMetadataProjects += "<MSBuild Projects=`"`@(ProjectToBuildProjects)`" ContinueOnError=`"ErrorAndStop`" StopOnFirstFailure=`"true`" Properties=`"ProjectToBuild=$($ProjectPath);DestinationDir=`$(DestinationPathsProp$($ProjectIndex));ReferencePath=`$(ReferencePathsProp$($ProjectIndex))`" />"
        }
        # Generate the MSBuild task to build the X++ modules.
        elseif ($Type -eq "Metadata")
        {
            # Check if module was found by metadata provider.
            if ($ModulesAndModels.Contains($Name))
            {
                $ModuleIndex += 1
                $ModuleName = $Name
                $ModelNames = $ModulesAndModels[$ModuleName]

                $ExistingModulePath = Join-Path -Path $DeploymentMetadataPath -ChildPath $ModuleName
                            
                # Create folder for module in deployment's metadata directory.
                if (!(Test-Path -Path $ExistingModulePath))
                {
                    Write-Message "- Creating directory: $ExistingModulePath" -Diag
                    $NewDirectory = New-Item -Path $ExistingModulePath -ItemType Directory -Force
                }
            
                # Copy the module source code to the deployment's metadata directory.
                $ModuleSourcePath = Join-Path -Path $MetadataPath -ChildPath $ModuleName
                Write-Message "- Copying $ModuleSourcePath to $DeploymentMetadataPath ..." -Diag
                Copy-Item -Path $ModuleSourcePath -Destination $DeploymentMetadataPath -Recurse -Force
                            
                $ModulesToBuild += "<ModuleToBuild$($ModuleIndex)>$($ModuleName)</ModuleToBuild$($ModuleIndex)>"
                $ModelsToBuild += "<ModelsToBuild$($ModuleIndex)>$($ModelNames)</ModelsToBuild$($ModuleIndex)>"

                Write-Message "- Creating the MSBuild task to build the x++ module." -Diag
                $BuildMetadataProjects += "<MSBuild Projects=`"`@(ProjectToBuildMetadata)`" ContinueOnError=`"ErrorAndStop`" StopOnFirstFailure=`"true`" Properties=`"ModuleToBuild=`$(ModuleToBuild$($ModuleIndex));ModelsToBuild=`$(ModelsToBuild$($ModuleIndex))`"/>"
            }
            # Check if package was found as runtime package.
            elseif ($RuntimePackages -icontains $Name)
            {
                $RuntimePackageName = $Name
                $TargetRuntimePackagePath = Join-Path -Path $DeploymentMetadataPath -ChildPath $RuntimePackage
            
                # Create folder for package in deployment metadata directory.
                if (!(Test-Path -Path $TargetRuntimePackagePath))
                {
                    Write-Message "- Creating directory: $TargetRuntimePackagePath" -Diag
                    $NewDirectory = New-Item -Path $TargetRuntimePackagePath -ItemType Directory -Force
                    
                    # Create customization file to track that this package was added by the build process.
                    $CustomizationFile = Join-Path -Path $TargetRuntimePackagePath -ChildPath "Customization.txt"
                    "Runtime-only customization added by build process on $([DateTime]::Now)." | Out-File -FilePath $CustomizationFile -Force
                }
                else
                {
                    Write-Message "Package folder already exists in deployment: $($TargetRuntimePackagePath)" -Warning
                }
            
                # Copy runtime package to the deployment metadata directory if it was part of VSTS code.
                $SourceRuntimePackagePath = Join-Path -Path $MetadataPath -ChildPath $RuntimePackageName
                if (Test-Path -Path $SourceRuntimePackagePath)
                {
                    Write-Message "- Copying $SourceRuntimePackagePath to $DeploymentMetadataPath ..." -Diag
                    Copy-Item -Path $SourceRuntimePackagePath -Destination $DeploymentMetadataPath -Recurse -Force
                }
            }
        }
        else
        {
            throw "Invalid project type '$($Type)'. Project type must be either Project or Metadata."
        }
    }

    # Creating the orchestrating proj file.
    $Metadata_Project_Build_Project = Join-Path -Path $SrcPath -ChildPath "Metadata_Project_Build.proj"
    Write-Message "- Creating project: $Metadata_Project_Build_Project" -Diag

    $Metadata_Project_Build = New-Item -Path $Metadata_Project_Build_Project -Type File -Force -Value @"
<?xml version="1.0" encoding="utf-8"?>
<Project xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <ItemGroup>
    <ProjectToBuildMetadata Include="`$(registry:HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Dynamics\AX\7.0\SDK@DynamicsSDK)\Metadata\BuildMetadata.proj"/>     
    <ProjectToBuildProjects Include="`$(registry:HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Dynamics\AX\7.0\SDK@DynamicsSDK)\Projects\BuildProjects.proj"/>     
  </ItemGroup>
  <ItemGroup>
    $([string]::Join("$([Environment]::NewLine)    ", $ReferencePathItemGroup).Trim())
  </ItemGroup>
  <ItemGroup>
    $([string]::Join("$([Environment]::NewLine)    ", $DestinationPathItemGroup).Trim())
  </ItemGroup>
  <PropertyGroup>
    $([string]::Join("$([Environment]::NewLine)    ", $ModulesToBuild).Trim())
    $([string]::Join("$([Environment]::NewLine)    ", $ModelsToBuild).Trim())
  </PropertyGroup>
  <Target Name="BuildModules">
    <PropertyGroup>
      $([string]::Join("$([Environment]::NewLine)      ", $ReferencePathProp).Trim())
    </PropertyGroup>
    <PropertyGroup>
      $([string]::Join("$([Environment]::NewLine)      ", $DestinationPathProp).Trim())
    </PropertyGroup>
    $([string]::Join("$([Environment]::NewLine)    ", $BuildMetadataProjects).Trim())
  </Target>
</Project>
"@

}


[int]$ExitCode = 0
try
{
    $vswherePath = $("${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe")
    if ( (Test-Path $vswherePath) -eq $true)
    {
        [xml]$vsInstances = & $vswherePath -format xml -version "[15.0, 16.0)"
        if ($vsInstances.instances -ne $null)
        {            
            if ($vsInstances.instances.instance.Count -gt 0)
            {
                write-Message "Visual Studio Instances found - $($vsInstances.instances.instance.Count)"
                $vsInstallationPath = $vsInstances.instances.instance[0].installationPath
                Write-Message "First instance - $VSInstallationPath"
            }
            else
            {
                $vsInstallationPath = $vsInstances.instances.instance.installationPath
            }

            Write-Message "Microsoft Visual Studio 2017 is found at path $($vsInstallationPath)"
            # If VS2017 is installed on the box, check if msbuild 15 is used or not
            Write-Message "MSBuildBinPath - $MSbuildBinPath"
            if (-not [string]::IsNullOrEmpty($MSbuildBinPath))
            {
                $cmd = "$MSbuildBinPath\MSBuild.exe" 
                $version = & $cmd "/version" "/nologo"
                Write-Message "Found MSBuild version: $version"
                [version]$ver = $version
                if ($ver.Major -lt 15)
                {
                    Write-Message "Build Definition should be updated to use msbuild 15 or higher, current version is : $version" -Warning
                }
            }
        }
        else
        {
            Write-Message "Microsoft Visual Studio 2017 or higher version is not found" -Warning
        }
    }

    Write-Message "Generating build projects for models in: $MetadataPath"
    
    if ([String]::IsNullOrEmpty($MetadataPath))
    {
        throw "No valid path is specified in MetadataPath parameter."
    }

    if (!(Test-Path -Path $MetadataPath))
    {
        throw "Specified metadata path does not exist: $MetadataPath"
    }

    # Get the deployment's binaries and metadata directory from registry.
    Write-Message "Getting deployment directory from registry..."
    $DeploymentBinariesPath = Get-AX7SdkDeploymentBinariesPath
    if (!$DeploymentBinariesPath)
    {
        throw "No deployment binaries path could be found in Dynamics SDK registry."
    }
    if (!(Test-Path -Path $DeploymentBinariesPath))
    {
        throw "The deployment binaries path from Dynamics SDK registry does not exist at: $DeploymentBinariesPath"
    }
    $DeploymentMetadataPath = Get-AX7SdkDeploymentMetadataPath
    if (!$DeploymentMetadataPath)
    {
        throw "No deployment metadata path could be found in Dynamics SDK registry."
    }
    if (!(Test-Path -Path $DeploymentMetadataPath))
    {
        throw "The deployment metadata path from Dynamics SDK registry does not exist at: $DeploymentMetadataPath"
    }

    # Add required types.
    Write-Message "Adding required types for metadata API..."
    Add-Type -Path (Join-Path -Path $DeploymentBinariesPath -ChildPath "Microsoft.Dynamics.AX.Metadata.Storage.dll")

    # Get metadata provider for the specified metadata path.
    Write-Message "Finding models in: $MetadataPath"
    $MetadataProvider = Get-MetadataProvider -Path $MetadataPath
    if ($MetadataProvider -ne $null -and $MetadataProvider.Count -gt 0)
    {
        # Get all models.
        Write-Message "- Getting model info from metadata provider and sort it by precedence..." -Diag
        $ModelsInfo = $MetadataProvider[0].ModelInfoProvider.ListModelInfos()

        if ($ModelsInfo.Count -gt 0)
        {
            # Create an ordered dictionary because Hastables do not guarantee any ordering
            $ModulesAndModels = New-Object System.Collections.Specialized.OrderedDictionary

            Write-Message "- Processing $($ModelsInfo.Count) models..." -Diag
            foreach ($Model in $ModelsInfo)
            {
                $ModuleName = $Model.Module
                $ModelName = $Model.Name
                Write-Message "- Model: $ModelName (Package: $ModuleName)" -Diag

                # Store module name and list of model names.
                if ($ModulesAndModels.Contains($ModuleName))
                {
                    $ModuleModelNames = $ModulesAndModels[$ModuleName]
                    $ModulesAndModels[$ModuleName] = "$($ModuleModelNames);$($ModelName)"
                }
                else
                {
                    $ModulesAndModels.Add($ModuleName, $ModelName)
                }
            }

            if ($ModulesAndModels.Count -eq 0)
            {
                throw "No valid models found in metadata path: $MetadataPath"
            }

            # Get list of all folders in packages to assume as include folder for runtime package loading
            $RuntimeIncludes = Get-ChildItem $MetadataPath -Directory | Select-Object -ExpandProperty Name
            if (!$RuntimeIncludes)
            {
                $RuntimeIncludes = @()
            }

            # Packages include folders could be source packages already deployed which we need to exclude, so get list of those
            $DeploymentMetadataProvider = Get-MetadataProvider -Path $DeploymentMetadataPath
            $DeployedCodePackages = $DeploymentMetadataProvider[0].ModelInfoProvider.ListModules() | Select-Object -ExpandProperty Name

            # Remove all packages from MissingPackages for which source code exists in the deployment folder,
            # leaving us with potential folders to load missing runtime packages from
            $RuntimeIncludes = @($RuntimeIncludes | Where-Object { $DeployedCodePackages -inotcontains $_ })
        }
        else
        {
            Write-Message "No models returned by model info provider from metadata path: $MetadataPath" -Warning
        }

        # If any metadata packages were found, generate projects to build them.
        Write-Message "Found $($ModulesAndModels.Count) packages to build."
        if ($ModulesAndModels.Count -gt 0)
        {
            if ($ProjectMetadataDependencyXml)
            {
                # If a dependency XML file is specified, use it to orchestrate the build order.
                # This allows building custom C# projects as well as X++ packages.
                GenerateCustomBuildMetadataProj -DependencyXmlFileName $ProjectMetadataDependencyXml -ModulesAndModels $ModulesAndModels -MetadataPath $MetadataPath -DeploymentMetadataPath $DeploymentMetadataPath -RuntimePackages $RuntimeIncludes
            }
            else
            {
                # No dependency XML file was specified. Build all source code packages discovered by metadata provider (no C# projects will be built).
                # Copy the source code and runtime package files to the deployment metadata directory and
                # generate a Metadata_Project_Build proj file that builds the models in the correct order.
                GenerateDefaultBuildMetadataProj -ModelsInfo $ModelsInfo -ModulesAndModels $ModulesAndModels -MetadataPath $MetadataPath -DeploymentMetadataPath $DeploymentMetadataPath -RuntimePackages $RuntimeIncludes
            }
        }
        else
        {
            Write-Message "No packages found to create build projects for." -Warning
        }
    }
    else
    {
        throw "Failed to create metadata provider from metadata path: $MetadataPath"
    }

    Write-Message "Generating build projects complete."

    # Signal project generation stop
    & $InstrumentationScript -TaskGenerateProjFilesStop
}
catch [System.Exception]
{
    # Create error file for the build process to detect that an error occurred.
    if (![String]::IsNullOrEmpty($ErrorLogPath))
    {
        $ErrorLogFile = New-Item -Path $ErrorLogPath -Type File -Force -Value "Error generating build projects: $($_)"
    }
    
    Write-Message "- Exception thrown at $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())$([Environment]::NewLine)$($_.Exception.ToString())" -Diag
    Write-Message "Error generating build projects: $($_)" -Error
    $ExitCode = -1

    # Log exception in telemetry
    & $InstrumentationScript -ExceptionMarker -ExceptionString ($_.Exception.ToString())
}
Write-Message "Script completed with exit code: $ExitCode"
Exit $ExitCode
# SIG # Begin signature block
# MIIjnwYJKoZIhvcNAQcCoIIjkDCCI4wCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBcjhQ0tqQBAUjp
# EE2GflL2J3hkvl4y6Hwnm9/q5FIae6CCDYEwggX/MIID56ADAgECAhMzAAAB32vw
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
# BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQg8gq9c8ay
# 0cGNiEQiD0ah4645uHo/YAfSKdxyQIlcU6IwQgYKKwYBBAGCNwIBDDE0MDKgFIAS
# AE0AaQBjAHIAbwBzAG8AZgB0oRqAGGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbTAN
# BgkqhkiG9w0BAQEFAASCAQB/FoP7LpbAp9GBu8QaL/X3HJP47+mZ/mJZf9sH/1nW
# Q4IzM+nur1UOzEL67TS5oG01ml+pmvjay7DT+pAxUjgkbtINrMRk5TOBdXL40i7X
# ufVEYWREZsc3DhuWJw5fw9wJpTukpAEc/0eYmebfCRij8VYTV0MrrKitrLgTOxzZ
# mmzayiS8VgyRYP0+6wuzqtHu5Sh6EYmfr2hX/rhGPvY/+V6p6AP0C71za8SW+DRb
# r2nqiP2rb/udUPjuq4GJLXFJU8nVGBeLO6m5MMEGIw/rLTZPZXooDL/hpLArKFjK
# yPg/fSyrOCdn3/mzFnaIYnXpafrmqyjYPymQRRwh/zFmoYIS/jCCEvoGCisGAQQB
# gjcDAwExghLqMIIS5gYJKoZIhvcNAQcCoIIS1zCCEtMCAQMxDzANBglghkgBZQME
# AgEFADCCAVkGCyqGSIb3DQEJEAEEoIIBSASCAUQwggFAAgEBBgorBgEEAYRZCgMB
# MDEwDQYJYIZIAWUDBAIBBQAEICSQoJUDksoS34gqFih7YGRo6mhDWEALaz99JXZt
# a5fYAgZgPOsQ3u0YEzIwMjEwMzAzMDMwOTU4LjkzNVowBIACAfSggdikgdUwgdIx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1p
# Y3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEmMCQGA1UECxMdVGhh
# bGVzIFRTUyBFU046OEQ0MS00QkY3LUIzQjcxJTAjBgNVBAMTHE1pY3Jvc29mdCBU
# aW1lLVN0YW1wIFNlcnZpY2Wggg5NMIIE+TCCA+GgAwIBAgITMwAAATqNjTH3d0lJ
# wgAAAAABOjANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0Eg
# MjAxMDAeFw0yMDEwMTUxNzI4MjJaFw0yMjAxMTIxNzI4MjJaMIHSMQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQg
# SXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxJjAkBgNVBAsTHVRoYWxlcyBUU1Mg
# RVNOOjhENDEtNEJGNy1CM0I3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFt
# cCBTZXJ2aWNlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAzl8k518P
# lz8JTIXYn/O9OakqcWqdJ8ZXJhAks9hyLB8+ANW7Zngb1t7iw7TmgeooOwMnbhCQ
# QH14UwWd8hQFWexKqVpcIFnY3b15+PYmgVeQ4XKfWJ3PPMjTiXu73epXHj9XX7mh
# S2IVqwEvDOudOI3yQL8D8OOG24b+10zDDEyN5wvZ5A1Wcvl2eQhCG61GeHNaXvXO
# loTQblVFbMWOmGviHvgRlRhRjgNmuv1J2y6fQFtiEw0pdXKCQG68xQlBhcu4Ln+b
# YL4HoeT2mrtkpHEyDZ+frr+Ka/zUDP3BscHkKdkNGOODfvJdWHaV0Wzr1wnPuUgt
# ObfnBO0oSjIpBQIDAQABo4IBGzCCARcwHQYDVR0OBBYEFBRWoJ8WXxJrpslvHHWs
# rQmFRfPLMB8GA1UdIwQYMBaAFNVjOlyKMZDzQ3t8RhvFM2hahW1VMFYGA1UdHwRP
# ME0wS6BJoEeGRWh0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1
# Y3RzL01pY1RpbVN0YVBDQV8yMDEwLTA3LTAxLmNybDBaBggrBgEFBQcBAQROMEww
# SgYIKwYBBQUHMAKGPmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMv
# TWljVGltU3RhUENBXzIwMTAtMDctMDEuY3J0MAwGA1UdEwEB/wQCMAAwEwYDVR0l
# BAwwCgYIKwYBBQUHAwgwDQYJKoZIhvcNAQELBQADggEBAF435D6kAS2jeAJ8BG1K
# Tm5Az0jpbdjpqSvMLt7fOVraAEHldgk04BKcTmhzjbTXsjwgCMMCS+jX4Toqi0cn
# zcSoD2LphZA98DXeH6lRH7qQdXbHgx0/vbq0YyVkltSTMv1jzzI75Z5dhpvc4Uwn
# 4Fb6CCaF2/+r7Rr0j+2DGCwl8aWqvQqzhCJ/o7cNoYUfJ4WSCHs1OsjgMmWTmglu
# PIxt3kV8iLZl2IZgyr5cNOiNiTraFDq7hxI16oDsoW0EQKCV84nV1wWSWe1SiAKI
# wr5BtqYwJ+hlocPw5qehWbBiTLntcLrwKdAbwthFr1DHf3RYwFoDzyNtKSB/TJsB
# 2bMwggZxMIIEWaADAgECAgphCYEqAAAAAAACMA0GCSqGSIb3DQEBCwUAMIGIMQsw
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
# bGVzIFRTUyBFU046OEQ0MS00QkY3LUIzQjcxJTAjBgNVBAMTHE1pY3Jvc29mdCBU
# aW1lLVN0YW1wIFNlcnZpY2WiIwoBATAHBgUrDgMCGgMVAAclkdn1j1gXgdyvYj41
# B8rkNZ4IoIGDMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
# b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwDQYJ
# KoZIhvcNAQEFBQACBQDj6WOuMCIYDzIwMjEwMzAzMDkyMzU4WhgPMjAyMTAzMDQw
# OTIzNThaMHcwPQYKKwYBBAGEWQoEATEvMC0wCgIFAOPpY64CAQAwCgIBAAICD44C
# Af8wBwIBAAICE90wCgIFAOPqtS4CAQAwNgYKKwYBBAGEWQoEAjEoMCYwDAYKKwYB
# BAGEWQoDAqAKMAgCAQACAwehIKEKMAgCAQACAwGGoDANBgkqhkiG9w0BAQUFAAOB
# gQAbjX80ZyaFuuhdQv6PPWmvmLsGh+lCZrw6JJjFiBKW1wI8aTDq5Y1IoG3AGDOJ
# pmbVM/7hkZc0AoXYNm/m83XMW8jeWPIvKTIMa3c/gpJw+//qZaYv5n3PG5t0kO6h
# E4XUFSxRShMdymZgF92N7IK/tx91OxmVEh/Ds7xbGHZJ7jGCAw0wggMJAgEBMIGT
# MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMT
# HU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAABOo2NMfd3SUnCAAAA
# AAE6MA0GCWCGSAFlAwQCAQUAoIIBSjAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQ
# AQQwLwYJKoZIhvcNAQkEMSIEINWRoQNDpf6KfJV1dQD3wUoehwA2TMPsY6hoRmiZ
# R28vMIH6BgsqhkiG9w0BCRACLzGB6jCB5zCB5DCBvQQgn6/QhAepLF/7Bdsvfu8G
# OT+ihL9c4cgo5Nf1aUN8tG0wgZgwgYCkfjB8MQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQ
# Q0EgMjAxMAITMwAAATqNjTH3d0lJwgAAAAABOjAiBCBAvyjUgoprQFx4gDZDdGTQ
# ySubQv3a7N7Q09Z8nT/LGjANBgkqhkiG9w0BAQsFAASCAQB9AexkZ/tqfQmkT3gO
# m1Erp5UvPaKQKaHpxhY2kDXFhWLCK4YUMRV6CXnFCOCApwFiectnXWZpAWS/cTJ6
# /0m/YAJ1EY17LEvm8c3q3IDSLjEC/iB8ivjWC4fRVI70YIKC7D13qVCJTU/kW5Xk
# fGMVr4hMjYvseNnXCAKzFodYJIUrDIS+CgjZS+wEiLAu6l3+Q0tNgFAFgYd/91fX
# zKcTg8l1DrF44ZUxAmUuPiEVz6XKUGaD4/04PXst/W2hR4YwdKXdOmDwmKKqXBLV
# P3RhEDua3tc/X5Nj0IFBsGqYIOIx1iNClHcEjOdW610emmnyOdM7cOsP1lOEtVsb
# aJ26
# SIG # End signature block
