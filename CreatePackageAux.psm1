Set-StrictMode -Version "Latest"

# Package constants
Set-Variable defaultNamespace -Option Constant -Value "dynamicsax-"
Set-Variable nuspecNamespace -Option Constant -Value "http://schemas.microsoft.com/packaging/2011/08/nuspec.xsd"
Set-Variable sourceMetadataFolder -Option Constant -Value "source\appil\metadata\"
Set-Variable staticMetadataPackageName -Option Constant -Value "framework-staticmetadata"
Set-Variable zipExtension -Option Constant -Value ".zip"
Set-Variable nupkgExtension -Option Constant -Value ".nupkg"
Set-Variable dynamicstools -Option Constant "DynamicsTools"
Set-Variable dynamicstoolspath "c:\DynamicsTools"
Set-Variable nugetExecutable -Option Constant -Value "nuget.exe"
Set-Variable nugetLocation -Value (join-path $env:SystemDrive "$dynamicstools\$nugetExecutable")
Set-Variable zipLocation -Value (join-path $env:SystemDrive "$dynamicstools\7za.exe")

$metadataAssembliesLoaded = $false
$modelsInfoList = $null

function Import-MetadataAssemblies([string]$binDir)
{
       if($metadataAssembliesLoaded -eq $false)
       {
            write-host "Importing metadata assemblies"

              # Need load metadata.dll and any referenced ones, not flexible to pick the new added references
            $m_core = Join-Path $binDir Microsoft.Dynamics.AX.Metadata.Core.dll
            $m_metadata = Join-Path $binDir Microsoft.Dynamics.AX.Metadata.dll
            $m_storage = Join-Path $binDir Microsoft.Dynamics.AX.Metadata.Storage.dll
            $m_xppinstrumentation = Join-Path $binDir Microsoft.Dynamics.ApplicationPlatform.XppServices.Instrumentation.dll
            $m_management_core = Join-Path $binDir Microsoft.Dynamics.AX.Metadata.Management.Core.dll
            $m_management_delta = Join-Path $binDir Microsoft.Dynamics.AX.Metadata.Management.Delta.dll
            $m_management_diff = Join-Path $binDir Microsoft.Dynamics.AX.Metadata.Management.Diff.dll
            $m_management_merge = Join-Path $binDir Microsoft.Dynamics.AX.Metadata.Management.Merge.dll

            # Load required dlls, loading should fail the script run with exceptions thrown
            [Reflection.Assembly]::LoadFile($m_core) > $null
            [Reflection.Assembly]::LoadFile($m_metadata) > $null
            [Reflection.Assembly]::LoadFile($m_storage) > $null
            [Reflection.Assembly]::LoadFile($m_xppinstrumentation) > $null
            [Reflection.Assembly]::LoadFile($m_management_core) > $null
            [Reflection.Assembly]::LoadFile($m_management_delta) > $null
            [Reflection.Assembly]::LoadFile($m_management_diff) > $null
            [Reflection.Assembly]::LoadFile($m_management_merge) > $null

            $metadataAssembliesLoaded = $true
       }
}

function Create-DependencyNode([xml]$xmlDoc, $dependancyNode, $dependancyId, $dependancyVersion, $enforceVersionCheck)
{
    write-host "Found dependency $dependancyId"

    $refNode = $xmlDoc.CreateElement("dependency", $nuspecNamespace);
    $idAttribute = $xmlDoc.CreateAttribute("id")
    $idAttribute.Value = $dependancyId
    $refNode.Attributes.Append($idAttribute) > $null

#disable it for now as the version in the descriptor of the model currently mismatch the module in our app/plat branch, thus there are protential risk enabling this mode.
<#
    if($enforceVersionCheck)
    {
        $verAttribute = $xmlDoc.CreateAttribute("version")
        $verAttribute.Value = $dependancyVersion
        $refNode.Attributes.Append($verAttribute) > $null
    }
#>
    $dependancyNode.AppendChild($refNode) > $null
}

function Get-FrameworkModelInfo([string]$pName)
{
    if ($pName -eq $staticMetadataPackageName)
    {
        $modelInfo = New-Object Microsoft.Dynamics.AX.Metadata.MetaModel.ModelInfo
        $modelInfo.Name = $pName
        $modelInfo.DisplayName = "Static Metadata"
        $modelInfo.Description = "Microsoft Dynamics 365 Unified Operations static metadata"
        $modelInfo.Publisher = "Microsoft Corporation"
        $modelInfo.VersionMajor = 7
        $modelInfo.VersionMinor = 0
        $modelInfo.VersionBuild = 0
        $modelInfo.VersionRevision = 0
    }

    return $modelInfo
}

function Get-ModelsInfo([string]$metadataDir)
{
    $metadataFactory = New-Object Microsoft.Dynamics.AX.Metadata.Storage.MetadataProviderFactory
    $diskProvider = $metadataFactory.CreateDiskProvider($metadataDir)
    #Get models belong to current package/module
    $modelsInfoList = $diskProvider.ModelManifest.ListModelInfos()
    return $modelsInfoList
}

function Get-ModelInfo([string]$pName, [string]$metadataDir, [string]$binDir)
{
    if ($null -eq $modelsInfoList)
    {
        $modelsInfoList = Get-ModelsInfo $metadataDir
    }

    return $modelsInfoList | Where-Object { $_.Module -match "^$pName$" }
}

function Get-ModelVersion([string]$pName, [string]$metadataDir, [string]$binDir)
{
    if ($null -eq $modelsInfoList)
    {
        $modelsInfoList = Get-ModelsInfo $metadataDir
    }

    #Get models belong to current package/module
    $modelInfoList = $modelsInfoList | Where-Object { $_.Module -match "^$pName$" }
    $highestVersion = [System.Version]::new()
    foreach ($modelInfo in $modelInfoList)
    {
        ##get the highest one
        $versionString = $modelInfo.VersionMajor.ToString() + '.' + $modelInfo.VersionMinor.ToString() + '.' + $modelInfo.VersionBuild.ToString() + '.' +$modelInfo.VersionRevision.ToString()
        $version = [System.Version]::new()
    
        if([System.Version]::TryParse($versionString, [ref]$version))
        {
            if($version.CompareTo($highestVersion) -gt 0)
            {
                $highestVersion = $version
            }
        }
    }
    
    if($highestVersion.Major -ge 1)
    {
        return $highestVersion.ToString()
    }
    else
    {
        return ''
    }
}

function Get-XppModuleDependencies([string]$pName, [string]$packageType, [string]$metadataDir, [string]$binDir)
{
    write-host "Getting dependencies for package '$pName' with type '$packageType'"

    $modelInfoList = Get-ModelInfo $pName $metadataDir $binDir

    [string[]] $modelReferences = @()
    [string[][]] $modelReferencesFull = @()
    foreach ($modelInfo in $modelInfoList)
    {
        foreach($reference in $modelInfo.ModuleReferences)
        {
            $refNuspecId = Get-PackageNuspecId $reference
            if ($packageType -eq "compile")
            {
                $refNuspecId += "-compile"
            }
            ElseIf ($packageType -eq "develop")
            {
                $refNuspecId += "-develop"
            }
            ElseIf ($packageType -eq "formadaptor")
            {
                $refNuspecId += "-formadaptor"
            }

            if ($modelReferences -notcontains $refNuspecId)
            {
                $modelReferences += ,$refNuspecId
            }
        }
    }

    foreach ($model in $modelReferences)
    {
        $modelReferencesVersion = Get-ModelVersion $($model.Replace($defaultNamespace,'')) $metadataDir $binDir
        $modelReferencesFull += ,@($model, $modelReferencesVersion)
    }

    $modelVersion = Get-ModelVersion $($pName.ToLower()) $metadataDir $binDir

    if ($packageType -eq "compile")
    {
        $runPackageName = $defaultNamespace + $pName.ToLower()
        $modelReferencesFull += ,@($runPackageName, $modelVersion)
    }
    ElseIf ($packageType -eq "develop")
    {
        $compilePackageName = $defaultNamespace + $pName.ToLower() + "-compile"
        $modelReferencesFull += ,@($compilePackageName, $modelVersion)
    }
    ElseIf ($packageType -eq "formadaptor")
    {
        $compilePackageName = $defaultNamespace + $pName.ToLower() + "-compile"
        $modelReferencesFull += ,@($compilePackageName, $modelVersion)
    }
    else
    {
        $staticMetadataVersion = Get-ModelVersion $staticMetadataPackageName $metadataDir $binDir
        # Add static metadata reference
        $modelReferencesFull += ,@($defaultNamespace + $staticMetadataPackageName,$staticMetadataVersion) 
    }

    return ,$modelReferencesFull
}

function Set-Dependencies ([string]$pName, [xml]$xmlDoc, $dependencyNode, [string[][]]$packageDependencies,[string]$packageVersion, [bool]$enforceVersionCheck)
{
    write-host "Setting dependencies '$packageDependencies' for package '$pName'"
  
    foreach ($dependency in $packageDependencies)
    {
        if($dependency.length -eq 1)
        {
            Create-DependencyNode $xmlDoc $dependencyNode $($dependency[0]) $packageVersion $enforceVersionCheck
        }
        else
        {
            Create-DependencyNode $xmlDoc $dependencyNode $($dependency[0]) $($dependency[1]) $enforceVersionCheck
        }
        write-host "Added depdendency '$($dependency[0])'"
    }
}

function Get-PackageFileName([string]$packageId, [string]$packageVersion)
{
       return "{0}.{1}" -f $packageId,$packageVersion
}

function Get-PackageNuspecId([string]$pName, [string]$packageType)
{
    [string]$packageId = $pName

    switch ($packageType)
    {
        "compile" { $packageId = $pName + "-compile" }
        "develop" { $packageId = $pName + "-develop" }
        "formadaptor" { $packageId = $pName + "-formadaptor" }
        default { $packageId = $pName }
    }

    return $defaultNamespace + $packageId.ToLower()
}

function Get-PackageNuspecDescription([string] $pName,[string] $packageType)
{
    switch ($packageType)
    {
        "run"     { return "The Runtime package of $pName."} 
        "compile" { return "The Compile time package of $pName."}
        "develop" { return "The Development time package of $pName."}
        "formadaptor" { return "The FormAdaptor package of $pName."}
        default { return "The package of $pName." }
    }
}

function Get-PackageNuspecSummary($packageId)
{
    return $pName
}

function Get-PackageNuspecTitle($packageId)
{
    return "Dynamics 365 Unified Operations: $packageId package"
}

function Get-PackageNuspecFileSourceName($packageId)
{
    $sourceName = $packageId + $zipExtension

    return $sourceName
}

function Create-WorkingPackageDir([string] $packageName)
{
    $packageDirectory = [System.IO.Path]::GetTempPath()
    $packageDirectory = Join-Path $packageDirectory $packageName
    if ((Test-Path $packageDirectory) -eq $true)
    {
        Remove-Item $packageDirectory -Force -Recurse
    }
    New-Item -ItemType directory -Path $packageDirectory > $null

    return $packageDirectory
}

function Delete-WorkingPackageDir($packageDirectory)
{
    if ((Test-Path $packageDirectory) -eq $true)
    {
        write-host "Cleaning up directory $packageDirectory"
        try
        {
            Remove-Item $packageDirectory -Force -Recurse
        }
        catch
        {
            write-host "Cleaning up directory $packageDirectory failed. Error: " + "$($_.Exception.Message)"
        }
    }
}

function Move-ItemCreateIfNotExists($source, $target)
{
    if(!(Test-Path $outputDir))
    {
        New-Item $outputDir -type Directory > $null
    }

    Move-Item $chocPackage $outputDir -Force -PassThru 
}

function Create-Nuspec([string] $pName, [string]$packageDir, [string[][]] $dependencies, [string]$packageId, [bool]$skipFiles=$false,[string]$packageVersion, [string]$copyRight, [bool]$isCompatibleWithSealedRelease = $false, [bool]$enforceVersionCheck = $false)
{
    write-host "Creating nuspec for package '$pName' with package id '$packageId' at directory '$packageDir'"

    [string]$fileName = $packageId + ".nuspec"
    [string]$srcPath = Join-Path $PSScriptRoot "NuspecTemplate.xml"
    [string]$destPath = Join-Path $packageDir $fileName

    write-host "Placing nuspec file at: $destPath"
    Copy-Item -Force $srcPath $destPath

    #Remove readonly flag
    $file = Get-Item $destPath
    if ($file.IsReadOnly -eq $true)
    {
        $file.IsReadOnly = $false
    }
    
    $xmlDoc = [xml](Get-Content $destPath)
    $xmlnsManager = New-Object System.Xml.XmlNamespaceManager -ArgumentList $xmlDoc.NameTable
    $xmlnsManager.AddNamespace("d", $nuspecNamespace)

    $xmlNode = $xmlDoc.SelectSingleNode("/d:package/d:metadata/d:id", $xmlnsManager)
    $xmlNode.InnerText = $packageId

    $xmlNode = $xmlDoc.SelectSingleNode("/d:package/d:metadata/d:version", $xmlnsManager)
    $xmlNode.InnerText = $packageVersion

    $xmlNode = $xmlDoc.SelectSingleNode("/d:package/d:metadata/d:authors", $xmlnsManager)
    $xmlNode.InnerText = "Microsoft"

    $xmlNode = $xmlDoc.SelectSingleNode("/d:package/d:metadata/d:owners", $xmlnsManager)
    $xmlNode.InnerText = "Microsoft"

    $xmlNode = $xmlDoc.SelectSingleNode("/d:package/d:metadata/d:requireLicenseAcceptance", $xmlnsManager)
    $xmlNode.InnerText = "false"
    write-host ("Set requireLicenseAcceptance '{0}'" -f $xmlNode.InnerText)

    $xmlNode = $xmlDoc.SelectSingleNode("/d:package/d:metadata/d:description", $xmlnsManager)
    $xmlNode.InnerText = Get-PackageNuspecDescription $packageId
    write-host ("Set description '{0}'" -f $xmlNode.InnerText)

    $xmlNode = $xmlDoc.SelectSingleNode("/d:package/d:metadata/d:summary", $xmlnsManager)
    $xmlNode.InnerText = Get-PackageNuspecSummary $packageId
    write-host ("Set summary '{0}'" -f $xmlNode.InnerText)

    $xmlNode = $xmlDoc.SelectSingleNode("/d:package/d:metadata/d:title", $xmlnsManager)
    $xmlNode.InnerText = Get-PackageNuspecTitle $packageId
    write-host ("Set title '{0}'" -f $xmlNode.InnerText)

    $xmlNode = $xmlDoc.SelectSingleNode("/d:package/d:metadata/d:tags", $xmlnsManager)
    #TODO: Revisit to define relevant tags on package, which typically used for discovery purposes
    if($enforceVersionCheck -eq $true)
    {
        $xmlNode.InnerText = "admin CompatibleWithSealedRelease CompatibleWithApp81PlusRelease" #require admin privilege right
    }
    elseif($isCompatibleWithSealedRelease)
    {
        $xmlNode.InnerText = "admin CompatibleWithSealedRelease" #require admin privilege right
    }
    else
    {
        $xmlNode.InnerText = "admin" #require admin privilege right
    }
    write-host ("Set tags '{0}'" -f $xmlNode.InnerText)

    $xmlNode = $xmlDoc.SelectSingleNode("/d:package/d:metadata/d:copyright", $xmlnsManager)
    # TODO - Update based on input or at least the current year
    $xmlNode.InnerText = "$copyRight"
    write-host ("Set copyright '{0}'" -f $xmlNode.InnerText)

    $xmlNode = $xmlDoc.SelectSingleNode("/d:package/d:metadata/d:dependencies", $xmlnsManager)
    Set-Dependencies $pName $xmlDoc $xmlNode $dependencies $packageVersion $enforceVersionCheck
    
    #No files are included for meta-package 
    if(!($skipFiles))
    {
        $xmlNode = $xmlDoc.SelectSingleNode("/d:package/d:files", $xmlnsManager)
        $fileNode = $xmlDoc.CreateElement("file", $nuspecNamespace);
        $srcAttr = $xmlDoc.CreateAttribute("src")
        $srcAttr.Value = "tools\**"
        $fileNode.Attributes.Append($srcAttr) > $null
        $targetAttr = $xmlDoc.CreateAttribute("target")
        $targetAttr.Value = "tools"
        $fileNode.Attributes.Append($targetAttr) > $null
        $xmlNode.AppendChild($fileNode) > $null
    }

    $xmlDoc.Save($destPath)
    write-host "Finished creation of nuspec file $destPath'"
}

function Copy-Script([string] $packageName, [string] $packageId, $outDir, $scriptName, $targetName,[string]$packageVersion)
{
    $installPs = Join-Path $PSScriptRoot $scriptName

    $targetFile = Join-Path $outDir "tools\$targetName"
    New-Item -Type File -Force $targetFile > $null

    Write-Host "Copying script file from $installPs to $targetFile"

    Copy-Item $installPs $targetFile

    #Remove readonly flag
    $file = Get-Item $targetFile
    if ($file.IsReadOnly -eq $true)
    {
        $file.IsReadOnly = $false
    }
}

function Copy-CustomPowershellModule([string] $outDir,[string]$packageVersion)
{
    Copy-Script "" "" $outDir "dynamicspackagemanagement.psm1" "dynamicspackagemanagement.psm1" $packageVersion
}

function Copy-InstallScript([string] $packageName, [string] $packageId, $outDir, $scriptName,[string]$packageVersion)
{
    Copy-Script $packageName $packageId $outDir $scriptName "InstallPackage.ps1" $packageVersion
}

function Copy-UninstallScript([string] $packageName, [string] $packageId, [string] $outDir,[string] $scriptName,[string]$packageVersion)
{
    Copy-Script $packageName $packageId $outDir $scriptName "UninstallPackage.ps1" $packageVersion
}

function Create-InstallationConfigfile([string]$packageName, [string]$packageId, [string]$outDir, [string]$fileName, [string]$packageVersion)
{
    $targetFile = Join-Path $outDir "tools\$fileName"
    $ZipName = "{0}.zip" -f (Get-PackageFileName $packageId $packageVersion)

    New-Object psobject -property @{PackageName = "$PackageName"; ZipName = "$ZipName" } | 
    ConvertTo-Json | out-file $targetFile
}

function Prepare-PackageFiles([string]$packageDrop,[string]$packageName,[string]$outDir,[string]$zipLocation,[string]$packageId,[string[]]$includedFolders,[string[]]$excludedFolders,[string[]]$filetypesIncluded,[string[]]$filetypesExcluded,[string]$packageVersion)
{
    #Compile package drop points to an abosolute directory so no need to combine package name
    write-host "Preparing package files $packageDrop, $packageName, $outDir, $zipLocation, $packageId"

    if(-Not (Test-Path $packageDrop))
    {
        throw "Path not found: $PackageDrop"
    }
    
    Push-Location $packageDrop

    if (Test-Path $zipLocation)
    {
        Prepare-PackageFiles7Zip $packageDrop $packageName $outDir $zipLocation $packageId $includedFolders $excludedFolders $filetypesIncluded $filetypesExcluded $packageVersion
    }
    else
    {
        Prepare-PackageFilesCompressArchive $packageDrop $packageName $outDir $zipLocation $packageId $includedFolders $excludedFolders $filetypesIncluded $filetypesExcluded $packageVersion        
    }

    #No need to test file existence as cpack will fail anyway
    Pop-Location

    write-host "Finished prepare package files"
}

function Prepare-PackageFilesCompressArchive([string]$packageDrop,[string]$packageName,[string]$outDir,[string]$zipLocation,[string]$packageId,[string[]]$includedFolders,[string[]]$excludedFolders,[string[]]$filetypesIncluded,[string[]]$filetypesExcluded,[string]$packageVersion)
{
    $destFile = (Get-PackageFileName $packageId $packageVersion) + $zipExtension
    $destFileDir = Join-Path $outDir "files"
    $destFile = Join-Path $destFileDir $destFile
    
    if(Test-Path $destFile)
    {
        Remove-Item $destFile
    }
    if (!(Test-Path $destFileDir))
    {
        New-Item -Path $destFileDir -ItemType Directory > $null
    }

    $files = @()
    if($includedFolders -ne $null)
    {
        foreach($folder in $includedFolders)
        {
            $folderfiles = Get-ChildItem (Join-Path -Path $packageDrop -ChildPath $folder) -Recurse -Exclude $filetypesExcluded
            
            #Exclude XppMetadata sub-folder when pack develop metadata
            if($excludedFolders -ne $null)
            {
                foreach($excl in $excludedFolders)
                {
                    $files += $folderfiles | Where-Object { (!($_.Name -like $excl)) -and (!($_.FullName -like "*\$excl\*")) }
                }
            }
            else
            {
                $files += $folderfiles
            }
        }
    }

    if($filetypesIncluded -ne $null)
    {
        $files += Get-ChildItem (Join-Path -Path $packageDrop -ChildPath "*") -Include $filetypesIncluded -Exclude $filetypesExcluded
    }

    $tempFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath (New-Guid)
    if (!(Test-Path $tempFolder))
    {
        New-Item -Path $tempFolder -ItemType Directory > $null
    }

    try
    {
        # Due to Compress-Archive limitations on relative paths and include/exclude
        # We create a list of needed files and copy them to temp location, then zip
        Push-Location $packageDrop

        $files | ForEach-Object {
            $destination = (Join-Path -Path $tempFolder -ChildPath (Resolve-Path $_ -Relative))
            $directory = ([System.IO.Path]::GetDirectoryName($destination))
            if (!(Test-Path $directory -PathType Container))
            {
                New-Item -Path $directory -ItemType Directory > $null
            }
            Copy-Item $_ -Destination $destination
        }

        Compress-Archive -Path "$tempFolder\*" -DestinationPath $destFile
    }
    finally
    {
        Remove-Item -Path $tempFolder -Force -Recurse
        Pop-Location
    }
}

function Prepare-PackageFiles7Zip([string]$packageDrop,[string]$packageName,[string]$outDir,[string]$zipLocation,[string]$packageId,[string[]]$includedFolders,[string[]]$excludedFolders,[string[]]$filetypesIncluded,[string[]]$filetypesExcluded,[string]$packageVersion)
{
    $destFile = (Get-PackageFileName $packageId $packageVersion) + $zipExtension
    $destFileDir = Join-Path $outDir "files"
    $destFile = Join-Path $destFileDir $destFile

    if(Test-Path $destFile)
    {
        Remove-Item $destFile
    }

    $argumentList = "a -r -y -mx3"
    
    #Exclude XppMetadata sub-folder when pack develop metadata
    if($null -ne $excludedFolders)
    {
        foreach($folder in $excludedFolders)
        {
            $argumentList = $argumentList + " -xr!$folder"
        }
    }

    if($null -ne $includedFolders)
    {
        foreach($folder in $includedFolders)
        {
            $argumentList = $argumentList + " -ir!$folder"
        }
    }

    if($null -ne $filetypesIncluded)
    {
        foreach($file in $filetypesIncluded)
        {
            $argumentList = $argumentList + " -i!$file"
        }
    }

    if($null -ne $filetypesExcluded)
    {
        foreach($file in $filetypesExcluded)
        {
            $argumentList = $argumentList + " -x!$file"
        }
    }

    $argumentList = $argumentList + " `"$destFile`""

    write-host "Zip command: $zipLocation $argumentList at package directory: $packageDrop"

    $logFile = Join-Path $outDir "$packageId-zip.log"
    $errorLogFile = Join-Path $outDir "$packageId-ziperror.log"

    [int]$retryCount = 2

    while ($retryCount -gt 0)
    {
        try
        {
            $retryCount--
            $process = Start-Process $zipLocation -ArgumentList $argumentList -NoNewWindow -Wait -RedirectStandardOutput $logFile -RedirectStandardError $errorLogFile -PassThru
            try { if (!($process.HasExited)) { Wait-Process $process } } catch { }

            if(Test-Path $logFile)
            {
                $zipOutput = Get-Content $logFile -Encoding Ascii
            
                foreach ($line in $zipOutput)
                {
                    Write-Debug $line
                }
            }
            
            if ($process.ExitCode -ne 0)
            {
                if ($retryCount -eq 0)
                {
                    $errors = Get-Content $errorLogFile
                    throw "Zip command: $zipLocation $argumentList at package directory: $packageDrop failed after retry on error log. $errors, it can be possible that some of your project /process opened in vs is locking the file, please try close all vs instance and restart a new one to generate the package again."
                }
                write-host "Zip command: $zipLocation $argumentList at package directory: $packageDrop failed. Retry once more."
            }
            else
            {
                #Exit if no exception and exit code equals 0
                $retryCount = 0
            }
        }
        #Catch specific exception as we see cases that 7zip exit too fast.
        #Exception msg: Cannot process request because the process (1412) has exited.
        #The zip is successful though
        catch [System.InvalidOperationException] 
        {
            write-host "Zip command: $zipLocation $argumentList exit unexpected on known exception. $($_.Exception.Message)"
            $zipError = $false

            if (Test-Path $destFile)
            {
                if ((Get-Childitem $destFile).Length -eq 0)
                {
                    $zipError = $true
                }
                elseif (Test-Path $errorLogFile)
                {
                    $errors = Get-Content $errorLogFile -Raw
                    if (-not (($null -eq $errors) -or ($errors -match '\S')))
                    {
                        $zipError = $true
                    }
                }
            }

            #We are good if zip file exists with content and no errors on error log file
            if ($zipError -eq $false)
            {
                $retryCount = 0
            }
        }
        #Exception msg: Cannot process request because the process (1412) has exited.
        #The zip is successful though
        catch
        {
            write-host "Zip command: $zipLocation $argumentList exit unexpected on exception. Retry once more. $($_.Exception.Message)"
            if ($retryCount -eq 0)
            {
                throw "Zip command: $zipLocation $argumentList failed after retry on exception. $($_.Exception.Message)"
            }
        }
        finally
        {
            if (Test-Path $logFile)
            {
                Remove-Item -Path $logFile
            }

            if (Test-Path $errorLogFile)
            {
                Remove-Item -Path $errorLogFile
            }
        }
    }
}

function Create-AxPackage($nugetLocation, $packageName, $packageId, $outDir)
{
    write-host "Switching to directory '$outDir'"
    Push-Location $outDir

    if (!(Test-Path -Path $nugetLocation))
    {
        $nugetLocation = $nugetExecutable
    }

    write-host "Calling:& $nugetLocation -ArgumentList pack $packageId.nuspec -NoPackageAnalysis -NoNewWindow -Wait"

    [int]$retryCount = 2
    $exceptionCaught = $false
    while ($retryCount -gt 0)
    {
        try
        {
            $retryCount--
            Start-Process $nugetLocation -ArgumentList "pack $packageId.nuspec -NoPackageAnalysis" -NoNewWindow -Wait
        }
        catch
        {
            $exceptionCaught = $true
            write-host "Calling: $nugetLocation $packageId.nuspec exit unexpected. Retry once more. $($_.Exception.Message)."

            if ($retryCount -eq 0)
            {
                throw "Calling: $nugetLocation $packageId.nuspec failed after retries. $($_.Exception.Message)."
            }
        }

        if ($exceptionCaught -eq $false)
        {
            $Dir = Get-Childitem $outDir
            $List = $Dir | Where-Object {$_.Extension -eq $nupkgExtension} | Where-Object {$_.Name.StartsWith($packageId) } #Skip version number check

            if($null -eq $List)
            {
                $nuspecContent = Get-Content -Path "$packageId.nuspec"
                if ($retryCount -eq 0)
                {
                    throw "Failed to find nupkg file in $outDir. Nuspec:  `n$nuspecContent"
                }
                else
                {
                    write-host "Failed to find nupkg file in $outDir. Retry once more. Nuspec: `n$nuspecContent"
                }
            }
            else
            {
                $retryCount = 0
            }
        }
    }

    Pop-Location

    return $List.FullName
}

function Copy-AdditionalFilesToPackage([string]$packageDrop,[string]$outputDir,[string]$webRoot,[string]$packageDir,[string]$packageName)
{
    # copy the additional files to the $packageDrop\AdditionalFiles dir
    $filelocationsfile=join-path "$packageDrop" "FileLocations.xml"
    $target=Join-Path $packageDrop "AdditionalFiles"
    if(!(Test-Path "$target"))
    {
        Write-Host "Creating the directory '$target'"
        New-Item -ItemType Directory -Path $target -Force > $null
    }
    if(Test-Path $filelocationsfile)
    {
        [System.Xml.XmlDocument] $xd = new-object System.Xml.XmlDocument
        $xd.Load($filelocationsfile)
        $files=$xd.SelectNodes("//AdditionalFiles/File")
        foreach($file in $files)
        {
            # the combination of the destination and the relativepath denotes the dir where the additional file was dropped during deployment
            $fileSource=$file.Source
            # get the flile name only
            $fileName=[System.IO.Path]::GetFileName($fileSource)
            $destination=$file.Destination
            try
            {
                $relativePath=$file.RelativePath
            }
            catch
            {
                $relativePath = "."
            }

            switch($destination)
            {
                "AOSWeb" #enum for AOS webroot
                {
                    if(-not [string]::IsNullOrEmpty($webRoot))
                    {
                        $source=join-path "$webRoot" "$relativepath\$fileName"
                    }
                }

                "PackageBin" #enum for \packages\bin
                {
                    if(-not [string]::IsNullOrEmpty($packageDir))
                    {
                        $source=join-path "$packageDir" "bin\$fileName"
                    }
                }

                "ModuleBin" #enum for \<<modulename>>\bin
                {
                    $source=join-path $packageDir "$packageName\bin\$fileName"
                }

                "PackageDir" #enum for \packages\<<relativepath>>
                {
                    if(-not [string]::IsNullOrEmpty($packageDir))
                    {
                        $source=join-path "$packageDir" "$relativepath\$fileName"
                    }
                }
            }

            if(Test-Path "$source")
            {
                Write-Host "Copying '$source' to '$target'"
                Copy-Item -path:"$source" -destination:"$target" -Force
            }
        }

        Write-Host "Copying '$filelocationsfile' to '$outputDir'"
        Copy-Item -path:$filelocationsfile -Destination:$outputDir -force
    }
}

function Get-IsCompatibleWithSealedRelease([string]$metadataDir, [string]$packageName)
{
    $metadataProviderFactory = New-Object Microsoft.Dynamics.AX.Metadata.Storage.MetadataProviderFactory

    $diskProviderConfiguration = New-Object Microsoft.Dynamics.AX.Metadata.Storage.DiskProvider.DiskProviderConfiguration

    $diskProviderConfiguration.ValidateExistence = $false
    $diskProviderConfiguration.IncludeStatic = $true
    $diskProviderConfiguration.FireNotificationEvents = $true
    $diskProviderConfiguration.FireNotificationEventsForXppMetadata = $true

    $diskProviderConfiguration.MetadataPath = $metadataDir
    $diskProviderConfiguration.XppMetadataPath = $metadataDir

    $IMetadataProvider = $metadataProviderFactory.CreateDiskProvider($diskProviderConfiguration);

    $allModelInfos = $IMetadataProvider.ModelManifest.ListModelInfos();

    $isModuleContainsSysLayerCode = $false
    $isModuleContainsCustomLayerCode = $false

    # check the layer value for the modules in current model, 
    # If the module contains both Sys layer and Higher layer models, then it is not compatible with sealed release.
    foreach($model in $allModelInfos)
    {
        if($model.Module -eq $packageName)
        {
            if ($model.Layer -eq 0)
            {
                $isModuleContainsSysLayerCode = $true
            }

            if ($model.Layer -gt 0)
            {
                $isModuleContainsCustomLayerCode = $true
            }
        }
    }

    return !($isModuleContainsSysLayerCode -and $isModuleContainsCustomLayerCode)
}

function Create-MetadataPackage([string] $packageName,[string] $packageDrop,[string] $packageType,[string] $outputDir,[string]$metadataDir,[string]$packageVersion,[string]$binDir,[string]$copyRight,[string]$webRoot, [bool]$enforceVersionCheck)
{
    #fix the extra '" ' characters passed from VS when user add '\' at the end of directory path
    $outputDir = $outputDir.Replace('" ',"")

    #error out when the packageName contain space, which is not supported in Operations, packageName = Module name and we don't allow space in module name
    if($packageName.Contains(" "))
    {
        throw "Unable to create package for $packageName, space in module/package name is not allowed in Dynamics 365 Unified Operations"
    }

    write-host "Starting creation of x++ package '$packageName'"
    Import-MetadataAssemblies -binDir:$binDir
    $packageDirectory =  Create-WorkingPackageDir $packageName

    try
    {
        $stopWatch = New-Object System.Diagnostics.Stopwatch
        $stopWatch.Start()
        $packageId = Get-PackageNuspecId $packageName $packageType

        write-host "Getting x++ dependencies"

        $isCompatibleWithSealedRelease = Get-IsCompatibleWithSealedRelease -metadataDir $metadataDir -packageName $packageName

        [string[][]]$dependencies = Get-XppModuleDependencies $packageName $packageType $metadataDir $binDir
        Create-Nuspec $packageName $packageDirectory $dependencies $packageId $false $packageVersion $copyRight $isCompatibleWithSealedRelease $enforceVersionCheck
        Copy-InstallScript $packageName $packageId $packageDirectory "InstallPackage.ps1" $packageVersion
        Copy-UninstallScript $packageName $packageId $packageDirectory "UninstallPackage.ps1" $packageVersion
        Copy-CustomPowershellModule $packageDirectory $packageVersion
        Create-InstallationConfigfile $packageName $packageId $packageDirectory "InstallConfig.json" $packageVersion

        [string[]]$excludedFolders = @()
        [string[]]$includedFolders = @()
        [string[]]$filetypesIncluded=@()
        [string[]]$filetypesExcluded =@()

        if($packageType -eq "run")
        {
            # copy the filelocations.xml file to the package that is being assembled
            Copy-AdditionalFilesToPackage -packageDrop:$packageDrop -outputDir:$packageDirectory -webRoot:$webRoot -packageDir:$metadataDir -packageName:$packageName

            # a blocklist of directory names to exclude for the runtime package
            [string[]]$runtimeDirsBlockList = @()
            $descriptorPath = Join-Path  $packageDrop "Descriptor"
            
            if( Test-Path $descriptorPath)
            {
                $files=[System.IO.Directory]::EnumerateFiles($descriptorPath)
                foreach($file in $files){
                    [string]$filename=[System.IO.Path]::GetFileNameWithoutExtension($file)
                    $runtimeDirsBlockList += $filename
                }
            }
            $runtimeDirsBlockList += "Descriptor"
            $runtimeDirsBlockList += "XppMetadata"
            
            $dirs=[System.IO.Directory]::EnumerateDirectories($packageDrop,"*",[System.IO.SearchOption]::TopDirectoryOnly)
            foreach($dir in $dirs){
                [string]$directoryname=[System.IO.Path]::GetFileName($dir)
                if(!$runtimeDirsBlockList.Contains($directoryname)){
                    $includedFolders += $directoryname
                }
            }

            $filetypesIncluded = @("*.config","filelocations.xml","*.xref")
            $filetypesExcluded += "*.delete"
        }

        Prepare-PackageFiles $packageDrop $packageName $outputDir $zipLocation $packageId $includedFolders $excludedFolders $filetypesIncluded $filetypesExcluded $packageVersion
        $chocPackage = Create-AxPackage $nugetLocation $packageName $packageId $packageDirectory

        $result = Move-ItemCreateIfNotExists $chocPackage $outputDir

        $stopWatch.Stop()

        write-host ("Packaging $chocPackage elapsed time: {0} ms" -f $stopWatch.Elapsed.TotalMilliseconds)

        return $result.FullName
    }
    finally
    {
        Delete-WorkingPackageDir $packageDirectory
    }
}

function Create-MetadataPackageAux([string] $packageName,[string] $packageDrop,[string] $packageType,[string] $outputDir,[string]$metadataDir,[string]$packageVersion,[string]$binDir,[string]$copyRight,[string]$webRoot, [bool]$enforceVersionCheck, [string] $dynamicsToolsPath)
{
    Set-Variable dynamicstoolspath "$dynamicsToolsPath"

    Set-Variable nugetLocation -Value (join-path $dynamicstoolspath "$nugetExecutable")
    Set-Variable zipLocation -Value (join-path $dynamicstoolspath "7za.exe")

    #fix the extra '" ' characters passed from VS when user add '\' at the end of directory path
    $outputDir = $outputDir.Replace('" ',"")

    #error out when the packageName contain space, which is not supported in Operations, packageName = Module name and we don't allow space in module name
    if($packageName.Contains(" "))
    {
        throw "Unable to create package for $packageName, space in module/package name is not allowed in Dynamics 365 Unified Operations"
    }

    write-host "Starting creation of x++ package '$packageName'"
    Import-MetadataAssemblies -binDir:$binDir
    $packageDirectory =  Create-WorkingPackageDir $packageName

    try
    {
        $stopWatch = New-Object System.Diagnostics.Stopwatch
        $stopWatch.Start()
        $packageId = Get-PackageNuspecId $packageName $packageType

        write-host "Getting x++ dependencies"

        $isCompatibleWithSealedRelease = Get-IsCompatibleWithSealedRelease -metadataDir $metadataDir -packageName $packageName

        [string[][]]$dependencies = Get-XppModuleDependencies $packageName $packageType $metadataDir $binDir
        Create-Nuspec $packageName $packageDirectory $dependencies $packageId $false $packageVersion $copyRight $isCompatibleWithSealedRelease $enforceVersionCheck
        Copy-InstallScript $packageName $packageId $packageDirectory "InstallPackage.ps1" $packageVersion
        Copy-UninstallScript $packageName $packageId $packageDirectory "UninstallPackage.ps1" $packageVersion
        Copy-CustomPowershellModule $packageDirectory $packageVersion
        Create-InstallationConfigfile $packageName $packageId $packageDirectory "InstallConfig.json" $packageVersion

        [string[]]$excludedFolders = @()
        [string[]]$includedFolders = @()
        [string[]]$filetypesIncluded=@()
        [string[]]$filetypesExcluded =@()

        if($packageType -eq "run")
        {
            # copy the filelocations.xml file to the package that is being assembled
            Copy-AdditionalFilesToPackage -packageDrop:$packageDrop -outputDir:$packageDirectory -webRoot:$webRoot -packageDir:$metadataDir -packageName:$packageName

            # a blocklist of directory names to exclude for the runtime package
            [string[]]$runtimeDirsBlockList = @()
            $descriptorPath = Join-Path  $packageDrop "Descriptor"
            
            if( Test-Path $descriptorPath)
            {
                $files=[System.IO.Directory]::EnumerateFiles($descriptorPath)
                foreach($file in $files){
                    [string]$filename=[System.IO.Path]::GetFileNameWithoutExtension($file)
                    $runtimeDirsBlockList += $filename
                }
            }
            $runtimeDirsBlockList += "Descriptor"
            $runtimeDirsBlockList += "XppMetadata"
            
            $dirs=[System.IO.Directory]::EnumerateDirectories($packageDrop,"*",[System.IO.SearchOption]::TopDirectoryOnly)
            foreach($dir in $dirs){
                [string]$directoryname=[System.IO.Path]::GetFileName($dir)
                if(!$runtimeDirsBlockList.Contains($directoryname)){
                    $includedFolders += $directoryname
                }
            }

            $filetypesIncluded = @("*.config","filelocations.xml","*.xref")
            $filetypesExcluded += "*.delete"
        }

        Prepare-PackageFiles $packageDrop $packageName $outputDir $zipLocation $packageId $includedFolders $excludedFolders $filetypesIncluded $filetypesExcluded $packageVersion
        $chocPackage = Create-AxPackage $nugetLocation $packageName $packageId $packageDirectory

        $result = Move-ItemCreateIfNotExists $chocPackage $outputDir

        $stopWatch.Stop()

        write-host ("Packaging $chocPackage elapsed time: {0} ms" -f $stopWatch.Elapsed.TotalMilliseconds)

        return $result.FullName
    }
    finally
    {
        Delete-WorkingPackageDir $packageDirectory
    }
}

function New-XppRuntimePackageAux([string] $packageName, [string] $packageDrop, [string] $outputDir,[string]$metadataDir,[string]$packageVersion,[string]$binDir,  [string]$copyRight = "2015 Microsoft Corporation",[string]$webRoot, [bool]$enforceVersionCheck = $false, [string] $dynamicsToolsPath = "")
{
    return Create-MetadataPackageAux $packageName $packageDrop "run" $outputDir $metadataDir $packageVersion $binDir $copyRight $webroot $enforceVersionCheck $dynamicsToolsPath
}

function New-XppRuntimePackage([string] $packageName, [string] $packageDrop, [string] $outputDir,[string]$metadataDir,[string]$packageVersion,[string]$binDir,  [string]$copyRight = "2015 Microsoft Corporation",[string]$webRoot, [bool]$enforceVersionCheck = $false)
{
    return Create-MetadataPackage $packageName $packageDrop "run" $outputDir $metadataDir $packageVersion $binDir $copyRight $webroot $enforceVersionCheck
}

function New-XppCompilePackage([string] $packageName, [string] $packageDrop, [string] $outputDir,[string]$metadataDir,[string]$packageVersion,[string]$binDir,  [string]$copyRight = "2015 Microsoft Corporation",[string]$webroot, [bool]$enforceVersionCheck = $false)
{
    return Create-MetadataPackage $packageName $packageDrop "compile" $outputDir $metadataDir $packageVersion $binDir $copyRight $webRoot $enforceVersionCheck
}

function New-XppDevelopPackage([string] $packageName, [string] $packageDrop, [string] $outputDir,[string]$metadataDir,[string]$packageVersion,[string]$binDir,  [string]$copyRight = "2015 Microsoft Corporation",[string]$webroot, [bool]$enforceVersionCheck = $false)
{
    return Create-MetadataPackage $packageName $packageDrop "develop" $outputDir $metadataDir $packageVersion $binDir $copyRight $webRoot $enforceVersionCheck
}

function New-XppFormAdaptorPackage([string] $packageName, [string] $packageDrop, [string] $outputDir,[string]$metadataDir,[string]$packageVersion,[string]$binDir,  [string]$copyRight = "2015 Microsoft Corporation",[string]$webroot, [bool]$enforceVersionCheck = $false)
{
    return Create-MetadataPackage $packageName $packageDrop "formadaptor" $outputDir $metadataDir $packageVersion $binDir $copyRight $webRoot $enforceVersionCheck
}

Export-ModuleMember -Function `
New-XppRuntimePackage, `
New-XppRuntimePackageAux, `
New-XppCompilePackage, `
New-XppDevelopPackage, `
New-XppFormAdaptorPackage, `
Get-IsCompatibleWithSealedRelease

