<#
.SYNOPSIS
    Prepare the Dynamics AX environment for producing a build.

.DESCRIPTION
    This script is intended for use in the Dynamics AX build process to run
    before each build to update the Dynamics SDK registry values from the
    current Dynamics AX deployment configuration. It will also create and
    restore a backup of the metadata packages and if specified restore the
    Dynamics AX database from a backup.

.NOTES
    When running through automation, use the -LogPath option to redirect
    output to a log file rather than the console.

    Copyright © 2016 Microsoft. All rights reserved.
#>
[Cmdletbinding()]
Param(
    [Parameter(Mandatory=$false, HelpMessage="The Visual Studio Online project collection URL to connect to.")]
    [string]$VSO_ProjectCollection=$null,

    [Parameter(Mandatory=$false, HelpMessage="The Dynamics SDK path.")]
    [string]$DynamicsSdkPath=$null,

    [Parameter(Mandatory=$false, HelpMessage="The Dynamics SDK backup path.")]
    [string]$DynamicsSdkBackupPath=$null,

    [Parameter(Mandatory=$false, HelpMessage="The Dynamics database backup file to restore.")]
    [string]$DatabaseBackupToRestore=$null,

    [Parameter(Mandatory=$false, HelpMessage="The deployment Dynamics AX AOS website name.")]
    [string]$AosWebsiteName=$null,
    
    [Parameter(Mandatory=$false, HelpMessage="Include all files when restoring the metadata packages backup. By default files that are not modified during the build process are excluded.")]
    [switch]$RestorePackagesAllFiles,

    [Parameter(Mandatory=$false, HelpMessage="The full path to the file to write output to (If not specified the output will be written to the host).")]
    [string]$LogPath=$null
)

# Send build marker which will send JSON data with VSTS agent $env settings
$InstrumentationScript = Join-Path -Path $PSScriptRoot -ChildPath "DevALMInstrumentor.ps1"

# Import module for Write-Message and other common functions (Picks up $LogPath variable).
Import-Module $(Join-Path -Path $PSScriptRoot -ChildPath "DynamicsSDKCommon.psm1") -Function "Write-Message", "Set-AX7SdkRegistryValues", "Set-AX7SdkRegistryValuesFromAosWebConfig", "Get-AX7SdkDeploymentPackagesPath", "Get-AX7SdkBackupPath", "Get-AX7SdkDeploymentDatabaseName", "Get-AX7SdkDeploymentDatabaseServer", "Stop-AX7Deployment"

<#
.SYNOPSIS
    Get the backup path from registry or create one if not found.

.NOTES
    If no backup path is set under the DynamicsSdk registry key the first of the
    default paths that is avaiable will be used.
#>
function Get-BackupPath([string]$Purpose, [string[]]$DefaultPaths = @("I:\DynamicsBackup", "$($env:SystemDrive)\DynamicsBackup"))
{
    # Get the Dynamics SDK backup path.
    $BackupPath = Get-AX7SdkBackupPath

    # If not set, then use one of the default backup path options.
    if (!$BackupPath)
    {
        Write-Message "- No backup path set in registry. Checking default options..." -Diag
        foreach ($DefaultPath in $DefaultPaths)
        {
            Write-Message "- Checking availability of path: $DefaultPath" -Diag
        
            $BackupDriveInfo = New-Object System.IO.DriveInfo($DefaultPath)
            if ($BackupDriveInfo -ne $null -and $BackupDriveInfo.IsReady -eq $true -and $BackupDriveInfo.DriveType -ne [System.IO.DriveType]::NoRootDirectory)
            {
                $BackupPath = $DefaultPath
                Write-Message "- Drive is available. Selecting backup path: $BackupPath" -Diag

                # Create registry entry for BackupPath.
                Set-AX7SdkRegistryValues -BackupPath $BackupPath

                break
            }
            else
            {
                Write-Message "- Drive is not available: $DefaultPath" -Diag
            }
        }

        if (!$BackupPath)
        {
            throw "Unable to find a suitable backup path. Please use the DynamicsSdkBackupPath parameter with a valid path."
        }

        # Delete existing folder.
        $PurposeBackupPath = Join-Path -Path $BackupPath -ChildPath $Purpose
        if (Test-Path -Path $PurposeBackupPath -ErrorAction SilentlyContinue)
        {
            Write-Message "- Removing existing files in: $PurposeBackupPath" -Diag
            Invoke-Expression "cmd.exe /c rd /s /q $PurposeBackupPath"

            # Retest and throw if it still exists.
            if (Test-Path -Path $PurposeBackupPath -ErrorAction SilentlyContinue)
            {
                throw "Unable to delete existing folder: $PurposeBackupPath"
            }
        }
    }

    $PurposeBackupPath = Join-Path -Path $BackupPath -ChildPath $Purpose

    return $PurposeBackupPath
}

<#
.SYNOPSIS
    Backup the metadata packages. Use before the first build to preserve the original metadata packages.
.RETURN
    True if a new backup was created, false if one already exists.
#>
function Backup-AX7Packages([string]$BackupPath, [string]$DeploymentPackagesPath, [string]$LogLocation, [switch]$Overwrite)
{
    $Success = $false

    if ($BackupPath)
    {
        $BackupCompletePath = Join-Path -Path $BackupPath -ChildPath "BackupComplete.txt"
        
        if (Test-Path -Path $BackupPath -ErrorAction SilentlyContinue)
        {
            $RemoveBackup = $false
            if (Test-Path -Path $BackupCompletePath -ErrorAction SilentlyContinue)
            {
                if ($Overwrite)
                {
                    Write-Message "- Overwrite switch specified. Removing existing backup files in: $BackupPath" -Diag
                    $RemoveBackup = $true
                }
            }
            else
            {
                Write-Message "- Incomplete backup found. Removing existing backup files in: $BackupPath" -Diag
                $RemoveBackup = $true
            }

            if ($RemoveBackup)
            {
                Invoke-Expression "cmd.exe /c rd /s /q $BackupPath"

                # Retest and throw if it still exists.
                if (Test-Path -Path $BackupPath -ErrorAction SilentlyContinue)
                {
                    throw "Unable to delete existing backup folder: $BackupPath"
                }
            }
        }
        
        if (!(Test-Path -Path $BackupPath -ErrorAction SilentlyContinue))
        {
            Write-Message "Creating backup of metadata packages..."
            Write-Message "- Deployment metadata packages path: $DeploymentPackagesPath" -Diag
            Write-Message "- Backup metadata packages path: $BackupPath" -Diag

            # Check if drive is available and ready.
            $BackupDriveInfo = New-Object System.IO.DriveInfo($BackupPath)
            if ($BackupDriveInfo -ne $null -and $BackupDriveInfo.IsReady -eq $true -and $BackupDriveInfo.DriveType -ne [System.IO.DriveType]::NoRootDirectory)
            {
                if (Test-Path -Path $DeploymentPackagesPath -PathType Container)
                {
                    # Check if there is enough space available for a backup.
                    Write-Message "- Calculating space required for backup of $DeploymentPackagesPath ..." -Diag
                    $MetadataFiles = Get-ChildItem -Path $DeploymentPackagesPath -Recurse -File -ErrorAction SilentlyContinue
                    if ($MetadataFiles.Count -gt 0)
                    {
                        $BytesRequired = ($MetadataFiles | Measure-Object -Property Length -Sum).Sum
                        if ($BackupDriveInfo.AvailableFreeSpace -gt $BytesRequired)
                        {
                            Write-Message "- The drive of the metadata backup path has enough available space (Required: $($BytesRequired) bytes, Available: $($BackupDriveInfo.AvailableFreeSpace) bytes)." -Diag
                            $RoboCopyLog = Join-Path -Path $LogLocation -ChildPath "Backup-AX7Packages_RoboCopy.log"

                            # Backup deployment metadata (No /MT to limit disk fragmentation. Use /SL for copying symlink as symlink).
                            Write-Message "- Backing up $($BytesRequired) bytes in $($MetadataFiles.Count) files from $DeploymentPackagesPath to $BackupPath ..." -Diag
                            Write-Message "- Backup command: RoboCopy $DeploymentPackagesPath $BackupPath /MIR /COPYALL /E /R:3 /W:10 /NFL /NDL /NS /NC /NP /SL /LOG:`"$RoboCopyLog`"" -Diag
                            $Output = & RoboCopy $DeploymentPackagesPath $BackupPath /MIR /COPYALL /E /R:3 /W:10 /NFL /NDL /NS /NC /NP /SL /LOG:"$RoboCopyLog"

                            # Read log contents if it exists. If it does not exist, print output as it likely contains an error.
                            if (Test-Path -Path $RoboCopyLog -ErrorAction SilentlyContinue)
                            {
                                # The last 8 lines contains the summary.
                                $RoboCopyLogContent = Get-Content -Path $RoboCopyLog -Tail 8
                                Write-Message "- RoboCopy log contents (Last 8 lines):" -Diag
                                $RoboCopyLogContent | % { Write-Message $_ -Diag }
                            }
                            else
                            {
                                Write-Message "RoboCopy did not produce the expected log: $RoboCopyLog" -Warning
                                if ($Output)
                                {
                                    Write-Message "- RoboCopy output:" -Diag
                                    $Output | % { Write-Message $_ -Diag }
                                }
                            }
                            Write-Message "- Backup completed with RoboCopy exit code: $($LASTEXITCODE)." -Diag

                            # Robocopy exit codes 0 to 7 are usually ok.
                            if ($LASTEXITCODE -ge 0 -and $LASTEXITCODE -le 7)
                            {
                                $Success = $true
                            }

                            # Verify backup file count and byte size.
                            $BackupFiles = Get-ChildItem -Path $BackupPath -Recurse -File -ErrorAction SilentlyContinue
                            if ($BackupFiles.Count -gt 0)
                            {
                                $BackupBytes = ($BackupFiles | Measure-Object -Property Length -Sum).Sum
                                Write-Message "- Backup contains $($BackupBytes) bytes in $($BackupFiles.Count) files: $BackupPath" -Diag
                            
                                if ($BackupFiles.Count -ne $MetadataFiles.Count)
                                {
                                    Write-Message "- Backup file count does not match deployment metadata file count (Backup: $($BackupFiles.Count), Deployment metadata: $($MetadataFiles.Count))." -Warning
                                    $Success = $false
                                }
                            
                                if ($BackupBytes -ne $BytesRequired)
                                {
                                    Write-Message "- Backup size does not match deployment metadata size (Backup: $BackupBytes bytes, Deployment metadata: $BytesRequired bytes)." -Warning
                                    $Success = $false
                                }

                                if ($Success)
                                {
                                    # If the backup was successful, create a BackupComplete.txt file.
                                    "Backup of $($BackupBytes) bytes in $($BackupFiles.Count) files completed successfully at $([DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss"))." | Out-File -FilePath $BackupCompletePath -Force
                                }
                            }
                            else
                            {
                                Write-Message "- No files found in backup path: $BackupPath" -Warning
                                $Success = $false
                            }
                        }
                        else
                        {
                            Write-Message "- The drive of the metadata backup path does not have enough available space (Required: $($BytesRequired) bytes, Available: $($BackupDriveInfo.AvailableFreeSpace) bytes). No backup will be made." -Diag
                        }
                    }
                    else
                    {
                        Write-Message "- The deployment metadata path contains no files to backup." -Diag
                    }
                }
                else
                {
                    Write-Message "- The deployment metadata path does not exist." -Diag
                }
            }
            else
            {
                Write-Message "- The drive for the metadata backup path is not available: $BackupPath. No backup will be made." -Diag
            }

            if ($Success)
            {
                Write-Message "Metadata packages backup successfully created."
            }
            else
            {
                throw "Failed to create backup of metadata packages."
            }
        }
        else
        {
            Write-Message "A backup already exists at: $BackupPath. No new backup will be created."
        }
    }
    else
    {
        throw "No backup path specified."
    }

    $Success
}

<#
.SYNOPSIS
    Restore a backup of the metadata packages. Use before each build to restore the original metadata packages.
#>
function Restore-AX7Packages([string]$BackupPath, [string]$DeploymentPackagesPath, [string]$LogLocation, [switch]$RestoreAllFiles)
{
    if ($BackupPath)
    {
        if (Test-Path -Path $BackupPath -ErrorAction SilentlyContinue)
        {
            if ($DeploymentPackagesPath)
            {
                Write-Message "Restoring metadata packages from backup..."
                Write-Message "- Backup metadata packages path: $BackupPath" -Diag
                Write-Message "- Deployment metadata packages path: $DeploymentPackagesPath" -Diag
                Write-Message "- Restore all files: $RestoreAllFiles" -Diag
                $RoboCopyLog = Join-Path -Path $LogLocation -ChildPath "Restore-AX7Packages_RoboCopy.log"
                
                # Construct exclusions of what to restore from metadata backup to restore packages.
                # These exclusions are for files and folders that are never changed during the build process,
                # but may be changed by applying a binary hot fix (like Bin, Plugins, InstallationRecords, etc.).
                $ExcludeFiles = @()
                $ExcludeDirs = @()

                # Always exclude the backup complete flag generated by the backup process.
                $ExcludeFiles += "/XF"
                $ExcludeFiles += "BackupComplete.txt"
                
                if (!$RestoreAllFiles)
                {
                    # Exclude FileLocations.xml from all X++ packages (binary hot fix can modify these).
                    $ExcludeFiles += "/XF"
                    $ExcludeFiles += "FileLocations.xml"

                    # Find names of directories to exclude.
                    $ExcludeBackupNames = @()

                    # Detect all directories in the backup that contains an X++ package (has a descriptor sub-directory with at least one XML file).
                    # Exlude all directories that are not found to be X++ packages.
                    $Directories = Get-ChildItem -Path $BackupPath -Directory
                    foreach ($Directory in $Directories)
                    {
                        $DescriptorPath = Join-Path -Path $($Directory.FullName) -ChildPath "Descriptor"
                        # If no Descriptor directory exists, exclude.
                        if (!(Test-Path -Path $DescriptorPath -PathType Container -ErrorAction SilentlyContinue))
                        {
                            $ExcludeBackupNames += $Directory.Name
                        }
                        else
                        {
                            # If no XML files exist in Descriptor directory, exclude.
                            if (!(Test-Path -Path "$($DescriptorPath)\*.xml" -ErrorAction SilentlyContinue))
                            {
                                $ExcludeBackupNames += $Directory.Name
                            }
                        }
                    }

                    # Add backup directory exclusions for RoboCopy.
                    foreach ($DirName in $ExcludeBackupNames)
                    {
                        $ExcludeDirs += "/XD"
                        $ExcludeDirs += "`"$(Join-Path -Path $BackupPath -ChildPath $DirName)`""
                    }

                    # Detect all directories in the deployment that contains an X++ package (has a descriptor sub-directory with at least one XML file).
                    # Exlude all directories that are not found to be X++ packages and not already excluded from backup.
                    # Do not exclude directories with customizations made by the build process (has a Customization.txt file).
                    $ExcludeDeploymentDirs = @()
                    $Directories = Get-ChildItem -Path $DeploymentPackagesPath -Directory
                    foreach ($Directory in $Directories)
                    {
                        # If a Customization.txt file exists, do not exclude even if no descriptor files are found.
                        $CustomizationFilePath = Join-Path -Path $($Directory.FullName) -ChildPath "Customization.txt"
                        if (!(Test-Path -Path $CustomizationFilePath -ErrorAction SilentlyContinue))
                        {
                            $DescriptorPath = Join-Path -Path $($Directory.FullName) -ChildPath "Descriptor"
                            # If no Descriptor directory exists, exclude.
                            if (!(Test-Path -Path $DescriptorPath -PathType Container -ErrorAction SilentlyContinue))
                            {
                                if ($ExcludeBackupNames -inotcontains $Directory.Name)
                                {
                                    $ExcludeDeploymentDirs += $Directory.Name
                                }
                            }
                            else
                            {
                                # If no XML files exist in Descriptor directory, exclude.
                                if (!(Test-Path -Path "$($DescriptorPath)\*.xml" -ErrorAction SilentlyContinue))
                                {
                                    if ($ExcludeBackupNames -inotcontains $Directory.Name)
                                    {
                                        $ExcludeDeploymentDirs += $Directory.Name
                                    }
                                }
                            }
                        }
                    }

                    # Add deployment directory exclusions for RoboCopy.
                    foreach ($DirName in $ExcludeDeploymentDirs)
                    {
                        $ExcludeDirs += "/XD"
                        $ExcludeDirs += "`"$(Join-Path -Path $DeploymentPackagesPath -ChildPath $DirName)`""
                    }
                }
                
                # Restore with /MT and /LOG as it is much faster when most files do not need to be updated.
                Write-Message "- Restore command: RoboCopy $BackupPath $DeploymentPackagesPath /B /MIR /E /R:3 /W:10 /NFL /NDL /NS /NC /NP /SL /MT /LOG:`"$RoboCopyLog`" $ExcludeFiles $ExcludeDirs" -Diag
                $Output = & RoboCopy $BackupPath $DeploymentPackagesPath /MIR /E /R:3 /W:10 /NFL /NDL /NS /NC /NP /SL /MT /LOG:"$RoboCopyLog" @ExcludeFiles @ExcludeDirs

                # Read log contents if it exists. If it does not exist, print output as it likely contains an error.
                $RoboCopyLogContent = $null
                if (Test-Path -Path $RoboCopyLog -ErrorAction SilentlyContinue)
                {
                    $RoboCopyLogContent = Get-Content -Path $RoboCopyLog
                    Write-Message "- RoboCopy log contents (Last 8 lines):" -Diag
                    $RoboCopyLogContent | Select-Object -Last 8 | % { Write-Message $_ -Diag }
                }
                else
                {
                    Write-Message "RoboCopy did not produce the expected log: $RoboCopyLog" -Warning
                    if ($Output)
                    {
                        Write-Message "- RoboCopy output:" -Diag
                        $Output | % { Write-Message $_ -Diag }
                    }
                }
                Write-Message "- Metadata restored from backup with RoboCopy exit code: $($LASTEXITCODE)." -Diag

                # RoboCopy exit code flags:
                #  0 = No errors and no files copied.
                #  1 = No errors and one or more files copied.
                #  2 = Extra files or directories were detected.
                #  4 = Mismatched files or directories were detected.
                #  8 = Errors copying files or directories after all retry attempts.
                # 16 = Fatal error.
                # Robocopy exit codes 0 to 7 are usually ok. After using /MIR or /PURGE there have been cases where
                # one or more files were found in the destination path even though they did not exist in the backup
                # path. RoboCopy does not appear to retry the purging of these files. The cause of the error is likely
                # that the files are in use by some other process (even if it is an access denied error).
                if ($LASTEXITCODE -ge 0 -and $LASTEXITCODE -le 7)
                {
                    # Examine RoboCopy log content to detect any potential problems.
                    $RestoreProblems = 0
                    if ($RoboCopyLogContent)
                    {
                        try
                        {
                            # Example of observed errors in RoboCopy log content:
                            # 2016/05/06 02:54:27 ERROR 5 (0x00000005) Deleting Extra File J:\AosService\PackagesLocalDirectory\FOneModel\bin\Dynamics.AX.FOneModel.DeleteActions.runtime
                            # Access is denied.
                            $LogNextLines = 0
                            $FilesToVerify = @()
                            Write-Message "- Searching RoboCopy log for any potential restore problems..." -Diag
                            foreach ($Line in $RoboCopyLogContent)
                            {
                                if ($Line.Length -gt 0)
                                {
                                    # Match error lines and capture file path.
                                    if ($Line -imatch "\sERROR\s(?<ErrorCode>\d+)\s\(.*\)\s(?<Message>.*)\s(?<Path>\w:\\.*)")
                                    {
                                        Write-Message $Line -Diag
                                        if ($Matches.Path)
                                        {
                                            $FilesToVerify += $Matches.Path
                                        }
                                        $LogNextLines = 1
                                    }
                                    elseif ($LogNextLines -gt 0)
                                    {
                                        Write-Message $Line -Diag
                                        $LogNextLines--
                                    }
                                }
                            }

                            # If any errors were found, check if the file exist in both backup and packages path.
                            if ($FilesToVerify.Count -gt 0)
                            {
                                Write-Message "- Found $($FilesToVerify.Count) files to verify." -Diag
                                foreach ($File in $FilesToVerify)
                                {
                                    $BackupFile = $File -ireplace [Regex]::Escape($DeploymentPackagesPath), $BackupPath
                                    if (Test-Path -Path $File -ErrorAction SilentlyContinue)
                                    {
                                        if (Test-Path -Path $BackupFile -ErrorAction SilentlyContinue)
                                        {
                                            Write-Message "- File has been restored correctly: $File" -Diag
                                        }
                                        else
                                        {
                                            Write-Message "- File not purged: $File" -Warning
                                            $RestoreProblems++
                                        }
                                    }
                                    else
                                    {
                                        if (Test-Path -Path $BackupFile -ErrorAction SilentlyContinue)
                                        {
                                            Write-Message "- File not restored from backup: $File" -Warning
                                            $RestoreProblems++
                                        }
                                        else
                                        {
                                            Write-Message "- File has been purged correctly: $File" -Diag
                                        }
                                    }
                                }
                            }
                            else
                            {
                                Write-Message "- No files with potential problems found in RoboCopy log." -Diag
                            }
                        }
                        catch
                        {
                            Write-Message "Failed to detect potential problems in RoboCopy log: $($_)" -Warning
                        }
                    }

                    # If any potential problems were found, write warning.
                    if ($RestoreProblems -gt 0)
                    {
                        Write-Message "Found $($RestoreProblems) files which may not have been restored correctly. If these files are causing any problems, please check if any processes are keeping these files open and stop them before running another build." -Warning
                        Write-Message "Metadata packages restored from backup with $($RestoreProblems) warnings."
                    }
                    else
                    {
                        Write-Message "Metadata packages successfully restored from backup."
                    }
                }
                else
                {
                    throw "Failed to restore metadata backup from: $BackupPath"
                }
            }
            else
            {
                throw "No deployment metadata path specified."
            }
        }
        else
        {
            throw "Specified backup path does not exist: $BackupPath"
        }
    }
    else
    {
        throw "No backup path specified."
    }
}

<#
.SYNOPSIS
    Backup the AX7 database. Use before the first build to preserve the original database.
#>
function Backup-AX7Database([string]$BackupPath, [string]$BakFileName = "AxDBBackup.bak", [switch]$Overwrite)
{
    if ($BackupPath)
    {
        $BackupFilePath = Join-Path $BackupPath -ChildPath $BakFileName
        if ($Overwrite -and (Test-Path -Path $BackupFilePath -ErrorAction SilentlyContinue))
        {
            Write-Message "- Overwrite switch specified. Removing existing database backup file : $BackupFilePath" -Diag
            Remove-Item -Path $BackupFilePath -Force | Out-Null

            # Retest and throw if it still exists.
            if (Test-Path -Path $BackupFilePath -ErrorAction SilentlyContinue)
            {
                throw "Unable to delete existing backup file: $BackupFilePath"
            }
        }
        
        if (!(Test-Path -Path $BackupFilePath -ErrorAction SilentlyContinue))
        {
            # Check if drive is available and ready.
            $BackupDriveInfo = New-Object System.IO.DriveInfo($BackupPath)
            if ($BackupDriveInfo -ne $null -and $BackupDriveInfo.IsReady -eq $true -and $BackupDriveInfo.DriveType -ne [System.IO.DriveType]::NoRootDirectory)
            {
                # Check if the backup folder exists.
                if (!(Test-Path -Path $BackupPath -ErrorAction SilentlyContinue))
                {
                    Write-Message "- Creating database backup folder $BackupPath as it does not exist" -Diag
                    New-Item -Path $BackupPath -ItemType directory -Force | Out-Null
                    Write-Message "- Database backup folder $BackupPath created" -Diag
                }

                $DatabaseBackupRestoreScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "DatabaseBackupRestore.ps1"
                if (Test-Path -Path $DatabaseBackupRestoreScriptPath -ErrorAction SilentlyContinue)
                {
                    Write-Message "- Found database backup and restore script at: $DatabaseBackupRestoreScriptPath" -Diag
                    $DatabaseName = Get-AX7SdkDeploymentDatabaseName
                    $DatabaseServer = Get-AX7SdkDeploymentDatabaseServer
            
                    Write-Message "- Calling script to backup $($DatabaseName) on $($DatabaseServer) to $($BackupFilePath) ..." -Diag
                    & $DatabaseBackupRestoreScriptPath -BackupFile $BackupFilePath -DatabaseName $DatabaseName -DatabaseServer $DatabaseServer -Backup
                    Write-Message "- Database backup complete." -Diag
                }
                else
                {
                    throw "Database backup and restore script was not found at: $DatabaseBackupRestoreScriptPath"
                }
            }
            else
            {
                throw "The drive for the database backup path is not available: No backup will be made."
            }  
        }
        else
        {
            Write-Message "A backup already exists at: $BackupFilePath. No new backup will be created."
        }
    }
    else
    {
        throw "No backup path specified."
    }
}

<#
.SYNOPSIS
    Restore a backup of Dynamics AX database from the file specified.
#>
function Restore-AX7Database([string]$DatabaseBackupToRestore)
{
    if ($DatabaseBackupToRestore)
    {
        Write-Message "Restoring database from backup..."
        $DatabaseBackupRestoreScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "DatabaseBackupRestore.ps1"
        if (Test-Path -Path $DatabaseBackupRestoreScriptPath -ErrorAction SilentlyContinue)
        {
            Write-Message "- Found database backup and restore script at: $DatabaseBackupRestoreScriptPath" -Diag
            
            # If the specified file name is not a full path, prefix with databases backup path.
            if ([System.IO.Path]::IsPathRooted($DatabaseBackupToRestore))
            {
                $FullDatabaseBackupPath = $DatabaseBackupToRestore
            }
            else
            {
                Write-Message "- Specified database backup file is not rooted. Prefixing Databases backup path." -Diag
                $BackupPath = Get-BackupPath -Purpose "Databases"
                $FullDatabaseBackupPath = Join-Path -Path $BackupPath -ChildPath $DatabaseBackupToRestore
            }
            
            if (Test-Path -Path $FullDatabaseBackupPath -ErrorAction SilentlyContinue)
            {
                $DatabaseName = Get-AX7SdkDeploymentDatabaseName
                $DatabaseServer = Get-AX7SdkDeploymentDatabaseServer
            
                Write-Message "- Calling script to restore $($FullDatabaseBackupPath) to $($DatabaseName) on $($DatabaseServer) ..." -Diag
                & $DatabaseBackupRestoreScriptPath -BackupFile $FullDatabaseBackupPath -DatabaseName $DatabaseName -DatabaseServer $DatabaseServer -Restore
                Write-Message "- Database restore complete." -Diag
            }
            else
            {
                throw "Specified database backup file to restore was not found at: $FullDatabaseBackupPath"
            }
        }
        else
        {
            throw "Database backup and restore script was not found at: $DatabaseBackupRestoreScriptPath"
        }
    }
    else
    {
        Write-Message "- No database backup specified to restore." -Diag
    }
}

[int]$ExitCode = 0
try
{
    Write-Message "Preparing build environment..."

    Write-Message "Updating Dynamics SDK registry key with specified values..."
    Set-AX7SdkRegistryValues -DynamicsSDK $DynamicsSdkPath -TeamFoundationServerUrl $VSO_ProjectCollection -AosWebsiteName $AosWebsiteName -BackupPath $DynamicsSdkBackupPath

    Write-Message "Updating Dynamics SDK registry key with values from AOS web config..."
    Set-AX7SdkRegistryValuesFromAosWebConfig

    # Signal prepare for build start
    & $InstrumentationScript -BuildMarker
    & $InstrumentationScript -TaskPrepareForBuildStart

    # Stop IIS to ensure there are no files locked by the IIS process.
    Write-Message "Stopping Dynamics AX deployment..."
    Stop-AX7Deployment

    # Get deployment packages path.
    $DeploymentPackagesPath = Get-AX7SdkDeploymentPackagesPath
    if (!$DeploymentPackagesPath)
    {
        throw "No deployment packages path could be found in Dynamics SDK registry."
    }
    if (!(Test-Path -Path $DeploymentPackagesPath))
    {
        throw "The deployment packages path from Dynamics SDK registry does not exist at: $DeploymentPackagesPath"
    }

    # Get the Dynamics SDK backup path for Packages.
    $PackagesBackupPath = Get-BackupPath -Purpose "Packages"

    # Get a log location for creating additional log files.
    $LogLocation = (Get-Location).Path
    if ($LogPath)
    {
        # Use the same directory as the log file path specified.
        $LogLocation = Split-Path -Path $LogPath -Parent
        if (!(Test-Path -Path $LogLocation -PathType Container -ErrorAction SilentlyContinue))
        {
            New-Item -Path $LogLocation -ItemType Directory | Out-Null
        }
    }

    # Create packages backup (if it does not exist).
    $NewBackupCreated = Backup-AX7Packages -BackupPath $PackagesBackupPath -DeploymentPackagesPath $DeploymentPackagesPath -LogLocation $LogLocation

    # Restore packages backup (unless a new backup was just created).
    if (!$NewBackupCreated)
    {
        Restore-AX7Packages -BackupPath $PackagesBackupPath -DeploymentPackagesPath $DeploymentPackagesPath -LogLocation $LogLocation -RestoreAllFiles:$RestorePackagesAllFiles
    }
    
    if (!$DatabaseBackupToRestore)
    {
        $DatabaseBackupPath = Get-BackupPath -Purpose "Databases"
        Backup-AX7Database -BackupPath $DatabaseBackupPath
    }
    else
    {
        # Restore a database backup (if specified).
        Restore-AX7Database -DatabaseBackupToRestore $DatabaseBackupToRestore
    }

    # Signal prepare for build stop
    & $InstrumentationScript -TaskPrepareForBuildStop

    Write-Message "Preparing build environment complete."    
}
catch [System.Exception]
{
    Write-Message "- Exception thrown at $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())$([Environment]::NewLine)$($_.Exception.ToString())" -Diag
    Write-Message "Error preparing build environment: $($_)" -Error
    $ExitCode = -1

    # Log exception in telemetry
    & $InstrumentationScript -ExceptionMarker -ExceptionString ($_.Exception.ToString())
}
Write-Message "Script completed with exit code: $ExitCode"
Exit $ExitCode
# SIG # Begin signature block
# MIIjngYJKoZIhvcNAQcCoIIjjzCCI4sCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCs+11abfMQygO+
# pF2igbr6+GMR/V7zOdB4nEqg060BfqCCDYEwggX/MIID56ADAgECAhMzAAAB32vw
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
# BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQg0lQKybEz
# 05kQRPDvlqAb0xmacBJJvyidt2bw9UfGMVYwQgYKKwYBBAGCNwIBDDE0MDKgFIAS
# AE0AaQBjAHIAbwBzAG8AZgB0oRqAGGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbTAN
# BgkqhkiG9w0BAQEFAASCAQCtcqkHfLH3/Rw/4Iolj2DuC8oYwXHwb32/hdUQqj96
# OrSjdGwKJlxv13bDnNkSjmA/apRnI7nVGs4gIVp7EECK8gbhyVGrMKY03ZgV8N0Q
# TPcxAVDug/6cVYAIBH4Zcgqh7NUxQLaTyDxt0KFemH8q8FtqhMhxVSPc2J7Gbqrs
# aCmbK5P0G63ms+Z7vriHuc5N6R4ezMF065BHYQtohQnIF8Uzt4SLkUtv51cqhXJh
# DGedJfz7jB4m/FyvihOoRLYpVgzX41OdMLljNh4nO+Dy/5h6xskroKjWd5K89GNo
# /3QpLqsexQKMxrLXS4X+NLWzPA/6JqAIlp5jkCnLjMRpoYIS/TCCEvkGCisGAQQB
# gjcDAwExghLpMIIS5QYJKoZIhvcNAQcCoIIS1jCCEtICAQMxDzANBglghkgBZQME
# AgEFADCCAVkGCyqGSIb3DQEJEAEEoIIBSASCAUQwggFAAgEBBgorBgEEAYRZCgMB
# MDEwDQYJYIZIAWUDBAIBBQAEIOWuVgXD18x2LYlsp23FCpFqjCB+jlT10HKqEG94
# bRIGAgZgPSuf0ggYEzIwMjEwMzAzMDMwOTU4LjIwNFowBIACAfSggdikgdUwgdIx
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
# BDAvBgkqhkiG9w0BCQQxIgQgoMdTZiLIC/YKL/agcsOzAB7JqkWNjYWolIbXBDVz
# cdMwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCBRPwE8jOpzdJ5wdE8soG1b
# S846dP7vyFpaj5dzFV6t3jCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwAhMzAAABQa9/Updc8txFAAAAAAFBMCIEIDI8k+AZ2+qKrT0TjZ7LmA5G
# C+u5xZScebfL24KQIuXCMA0GCSqGSIb3DQEBCwUABIIBAHUUmq8qpN0UX5DxHyXl
# leyP58eqcewgx23lb6TBeo9C49GtNv44k5k4Nlz+BhxpiwIVRUQFk8ql4EVtXOVl
# kwvbSIfaTJSnKqv8C+J8kfIJS5XYC76S0ZrcnHL4xGLTHvv07GzrY4l+jOnR1rWt
# euv8/dwTnAsMvpPdUyBVjRW+n51IQJcYa5q5PSZviderPeMcEkGv0Z+LsdkQFrw6
# 4GVpGJ6/nBUv3ZwGLaIBlgalOwzLJ0sgV5uxvFIpyy/Yw5zQxNlEIp7zwdwKL8C6
# WiqO/xwHzceggs654Zyww1fbKJmxt+bTBu6qIHxk9VjPvWIywRGSsxLX3rwhOfNZ
# lrU=
# SIG # End signature block
