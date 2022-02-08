 <#
.SYNOPSIS
    Backup a database to a file or restore a database from a file.

.DESCRIPTION
    This script is intended for use in the Dynamics AX Development environment
    to bring the database to the original state by restoring a .bak file and
    to create an initial backup of the original database before the first build.

.NOTES
    When running through automation, use the -LogPath option to redirect
    output to a log file rather than the console. When the console output is
    used a -Verbose option can be added to get more detailed output.

    Copyright © 2016 Microsoft. All rights reserved.
#>
[CmdletBinding()]
param
(
    [Parameter(Mandatory=$true, HelpMessage="The full path of the backup file.")]
	[string]$BackupFile,

    [Parameter(Mandatory=$false, HelpMessage="The name of the database to restore the backup file to.")]
	[string]$DatabaseName = "AXDBRAIN",

	[Parameter(Mandatory=$false, HelpMessage="The name of the database server.")]
	[string]$DatabaseServer = ".",
    
    [Parameter(Mandatory=$false, HelpMessage="The name of the master database.")]
    [string]$MasterDB="MASTER",

    [Parameter(Mandatory=$false, HelpMessage="Backup the database.")]
    [switch]$Backup,

    [Parameter(Mandatory=$false, HelpMessage="Restore the database.")]
    [switch]$Restore,

    [Parameter(Mandatory=$false, HelpMessage="Stop IIS and Dynamics AX services before restoring backup.")]
    [switch]$StopDeploymentService,

    [Parameter(Mandatory=$false, HelpMessage="Start IIS and Dynamics AX services after restoring backup.")]
    [switch]$StartDeploymentService,

    [Parameter(Mandatory=$false, HelpMessage="The full path to the file to write output to (If not specified the output will be written to the host).")]
    [string]$LogPath=$null
)

# Import module for Write-Message and other common functions (Picks up $LogPath variable).
Import-Module $(Join-Path -Path $PSScriptRoot -ChildPath "DynamicsSDKCommon.psm1") -Function "Write-Message", "Get-AX7SdkDeploymentMetadataPath", "Stop-AX7Deployment", "Start-AX7Deployment"

<#
.SYNOPSIS
    Executes the sql script block provided against the database name provided using windows authentication.
#>
function Invoke-SqlCommand([string]$DBName, [scriptblock]$scriptBlock)
{
    $result = $null
    $connectionstring_windowsauth = "Server=$($DatabaseServer);Database=$($DBName);Trusted_Connection=true"
    $sqlConnection = New-Object System.Data.SqlClient.SqlConnection $connectionstring_windowsauth
    Write-Message "- SQL connection string: $connectionstring_windowsauth" -Diag
    
    try
    {
        $sqlConnection.Open()
        $sqlCommand = $sqlConnection.CreateCommand()
        $result = Invoke-Command -ScriptBlock $scriptBlock -ArgumentList $sqlCommand
        $sqlConnection.Close()
    }
    finally
    {
        if ($sqlConnection -ne $null -and $sqlConnection.State -eq [System.Data.ConnectionState]::Open)
        {
            $sqlConnection.Close()
        }
    }
    return $result
}

<#
.SYNOPSIS
    SQL scripts to drop the database snapshots.
#>
function Drop-DatabaseSnapshot()
{
    $codeblock =
    {
        $sqlcmd = "SELECT name FROM sys.databases WHERE source_database_id=(SELECT database_id FROM sys.databases WHERE name=N'$DatabaseName')"
        Write-Message "- Running SQL command: $sqlcmd" -Diag
        $result = Invoke-SqlCommand $MasterDB {
            $sqlCommand.CommandText = $sqlcmd
            return $sqlCommand.ExecuteReader()
        }
        $snapshots = @()
        if ($result -ne $null)
        {
            $results = @($result)
            foreach ($sqlRecord in $results)
            {
                [string]$snapshotname = $sqlRecord.GetValue(0)
                Write-Message "- Identified database snapshot: $snapshotname" -Diag
                $snapshots += $snapshotname
            }
        }

        # Drop the snapshots.
        Write-Message "- Dropping $($snapshots.Count) snapshots..." -Diag
        foreach ($dbsnapshot in $snapshots)
        {
            $sqlcmd = "IF EXISTS (SELECT * FROM sys.databases where name=N'$dbsnapshot') BEGIN DROP DATABASE $dbsnapshot END"
            Write-Message "- Running SQL command: $sqlcmd" -Diag
            $result = Invoke-SqlCommand $MasterDB {
                $sqlCommand.CommandText = $sqlcmd
                $sqlCommand.ExecuteScalar()
            }
        }
    }

    ExecuteWith-Retry $codeblock "Drop database snapshot"
    Write-Message "Dropping the database snapshots completed successfully."
}

<#
.SYNOPSIS
    SQL script to drop the database.
#>
function Drop-Database()
{
    $codeblock =
    {
        # Kill all the connections to the database
        $sqlcmd = "DECLARE @kill varchar(8000) = ''; SELECT @kill = @kill + 'kill ' + CONVERT(varchar(5), spid) + ';' FROM $MasterDB..sysprocesses WHERE dbid = db_id(N'$DatabaseName') EXEC(@kill);"
        Write-Message "- Running SQL command: $sqlcmd" -Diag
        $result = Invoke-SqlCommand $MasterDB {
            $sqlCommand.CommandText = $sqlcmd
            $sqlCommand.ExecuteScalar()
        }

        $sqlcmd = "IF EXISTS (SELECT * FROM sys.databases where name=N'$DatabaseName') BEGIN DROP DATABASE $DatabaseName END"
        Write-Message "- Running SQL command: $sqlcmd" -Diag
        $result = Invoke-SqlCommand $MasterDB {
            $sqlCommand.CommandText = $sqlcmd
            $sqlCommand.ExecuteScalar()
        }
    }

    ExecuteWith-Retry $codeblock "Drop database"
    Write-Message "Dropping the database completed successfully."
}

<#
.SYNOPSIS
    Script to delete database data and log files from the disk.
#>
function Delete-ExistingDatabaseFiles()
{
    $codeblock =
    {
        $sqlcmd = "SELECT SERVERPROPERTY('instancedefaultdatapath'),SERVERPROPERTY('instancedefaultlogpath')"
        Write-Message "- Running SQL command: $sqlcmd" -Diag
        $result = Invoke-SqlCommand $MasterDB {
            $sqlCommand.CommandText = $sqlcmd
            return $sqlCommand.ExecuteReader()
        }

        if (($result.HasRows -and $result.Read()) -or $result.FieldCount -gt 0)
        {
            [string]$sqldatadir = $result.GetValue(0)
            Write-Message "- SQL default data path: $sqldatadir" -Diag
            [string]$sqllogdir = $result.GetValue(1)
            Write-Message "- SQL default log path: $sqllogdir" -Diag
        }

        $datafilename = "$($DatabaseName).mdf"
        $logfilename = "$($DatabaseName)_log.ldf"
        $dbfilepath = Join-Path -Path $sqldatadir -ChildPath $datafilename
        $dblogfilepath = Join-Path -Path $sqllogdir -ChildPath $logfilename

        Write-Message "- Database data file: $dbfilepath" -Diag
        Write-Message "- Database log file: $dblogfilepath" -Diag
           
        # Delete database data file.
        if (Test-Path -Path $dbfilepath -ErrorAction SilentlyContinue)
        {
            Write-Message "- Deleting the database data file." -Diag
            Remove-item $dbfilepath -Force -EA SilentlyContinue | out-null
        }

        # Delete database log file.
        if (Test-Path -Path $dblogfilepath -ErrorAction SilentlyContinue)
        {
            Write-Message "- Deleting the database log file." -Diag
            Remove-item $dblogfilepath -Force -EA SilentlyContinue | out-null
        }
    }

    ExecuteWith-Retry $codeblock "Delete existing SQL files"
    Write-Message "Deleting existing SQL files completed successfully."
}

<#
.SYNOPSIS
    SQL script to create the database.
#>
function Create-Database()
{
    $codeblock =
    {
        # Create database.
        $sqlcmd = "IF NOT EXISTS (SELECT 1 FROM SYS.DATABASES WHERE NAME = N'$DatabaseName') CREATE DATABASE [$DatabaseName]"
        Write-Message "- Running SQL command: $sqlcmd" -Diag
        $result = Invoke-SqlCommand $MasterDB {
            $sqlCommand.CommandText = $sqlcmd
            $sqlCommand.CommandTimeout=0
            $sqlCommand.ExecuteNonQuery()
        }
    }

    ExecuteWith-Retry $codeblock "Create database"
    Write-Message "Creating database completed successfully."
}

<#
.SYNOPSIS
    SQL script to set database properties
#>
function Set-DatabaseProperties()
{
    $codeblock =
    {
        try
        {
            # Set read commited snapshot isolation level if not already set.
            [bool]$setIsolationLevel = $true
            $sqlcmd = "DBCC USEROPTIONS"
            Write-Message "- Running SQL command: $sqlcmd" -Diag
            $connectionstring = "Server=$DatabaseServer;Database=$DatabaseName;Trusted_Connection=true"
            $connection = new-object system.data.sqlclient.sqlconnection($connectionstring)
            $adapter = new-object system.data.sqlclient.sqldataadapter($sqlcmd, $connection)
            $table = new-object system.data.datatable
            $adapter.Fill($table) | Out-Null
            foreach ($row in $table.Rows)
            {
                $option = $row["Set Option"]
                $value = $row["Value"]
                Write-Message "- DBCC useroptions: $($option) = $($value)" -Diag
                if ($option -ieq "isolation level" -and $value -ieq "read committed snapshot")
                {
                   Write-Message "- $DatabaseName database 'isolation level' is already set to 'read_committed_snapshot'." -Diag
                   $setIsolationLevel = $false
                }
            }
          
            if ($setIsolationLevel)
            {
                $sqlcmd = "ALTER DATABASE [$DatabaseName] SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE"
                Write-Message "- Running SQL command: $sqlcmd" -Diag
                $result = Invoke-SqlCommand $MasterDB {
                    $sqlCommand.CommandText = $sqlcmd
                    $sqlCommand.CommandTimeout = 0
                    $sqlCommand.ExecuteNonQuery()
                }
            }
        }
        finally
        {
            if ($connection -ne $null -and $connection.State -eq [System.Data.ConnectionState]::Open)
            {
                $connection.Close()
            }
        }
    }

    ExecuteWith-Retry $codeblock "Set database property"
    Write-Message "Setting database properties completed successfully."
}

<#
.SYNOPSIS
    SQL script to restore the database from the backup file.
#>
function Restore-Database([string]$BackupFilePath)
{
    $codeblock =
    {
        # Offline and restore the db.
        $sqlcmd = "ALTER DATABASE [$DatabaseName] SET OFFLINE WITH ROLLBACK IMMEDIATE; RESTORE DATABASE [$DatabaseName] FROM DISK=N'$BackupFilePath' WITH FILE = 1, REPLACE, STATS = 10"
        Write-Message "- Running SQL command: $sqlcmd" -Diag
        $result = Invoke-SqlCommand $MasterDB {
            $sqlCommand.CommandText = $sqlcmd
            $sqlCommand.CommandTimeout = 0
            $sqlCommand.ExecuteNonQuery()
        }

        # Get the logical name of the first db data file.
        $sqlcmd = "SELECT TOP 1 files.name FROM sys.databases dbs, sys.master_files files WHERE dbs.name=N'$DatabaseName' AND dbs.database_id = files.database_id AND type_desc=N'ROWS'"
        Write-Message "- Running SQL command: $sqlcmd" -Diag
        $result = Invoke-SqlCommand $MasterDB {
            $sqlCommand.CommandText = $sqlcmd
            $sqlCommand.ExecuteScalar()
        }
        if ($result)
        {
            $dataFileName = $result
        }
        else
        {
            throw "Failed to get database data file name."
        }

        # Get the logical name of the first db transaction log file.
        $sqlcmd = "SELECT TOP 1 files.name FROM sys.databases dbs, sys.master_files files WHERE dbs.name=N'$DatabaseName' AND dbs.database_id = files.database_id AND type_desc=N'LOG'"
        Write-Message "- Running SQL command: $sqlcmd" -Diag
        $result = Invoke-SqlCommand $MasterDB {
            $sqlCommand.CommandText = $sqlcmd
            $sqlCommand.ExecuteScalar()
        }
        if ($result)
        {
            $logFileName = $result
        }
        else
        {
            throw "Failed to get database transaction log file name."
        }

        # Change the data file to grow 256MB at a time, transaction log file by 512MB.
        [int]$dataFileGrowth = 256
        [int]$logFileGrowth = 512
        $sqlcmd = "ALTER DATABASE [$DatabaseName] MODIFY FILE (NAME=N'$dataFileName', FILEGROWTH=$($dataFileGrowth)MB); ALTER DATABASE [$DatabaseName] MODIFY FILE (NAME=N'$logFileName', FILEGROWTH=$($logFileGrowth)MB)"
        Write-Message "- Running SQL command: $sqlcmd" -Diag
        $result = Invoke-SqlCommand $MasterDB {
            $sqlCommand.CommandText = $sqlcmd
            $sqlCommand.CommandTimeout = 0
            $sqlCommand.ExecuteNonQuery()
        }

        # Shrink the transaction log and re-initialize to 4096MB (should result in 20 VLFs).
        # The most transaction log space required on the build machine is likely to be during
        # database synchronization. Observe and adjust as needed to avoid auto growth.
        [int]$logFileInitial = 4096
        $sqlcmd = "DBCC SHRINKFILE(N'$logFileName'); ALTER DATABASE [$DatabaseName] MODIFY FILE (NAME=N'$logFileName', SIZE=$($logFileInitial)MB)"
        Write-Message "- Running SQL command: $sqlcmd" -Diag
        $result = Invoke-SqlCommand $DatabaseName {
            $sqlCommand.CommandText = $sqlcmd
            $sqlCommand.CommandTimeout = 0
            $sqlCommand.ExecuteNonQuery()
        }

        # Online the db.
        $sqlcmd = "ALTER DATABASE [$DatabaseName] SET ONLINE";
        Write-Message "- Running SQL command: $sqlcmd" -Diag
        $result = Invoke-SqlCommand $MasterDB {
            $sqlCommand.CommandText = $sqlcmd
            $sqlCommand.CommandTimeout = 0
            $sqlCommand.ExecuteNonQuery()
        }
    }

    ExecuteWith-Retry $codeblock "Restore database"
    Write-Message "Restoring database completed successfully."
}

<#
.SYNOPSIS
    SQL script to create full test catalog for the database.
#>
function Create-DefaultFullTextCatalog()
{
    $codeblock =
    {
        $catalogName = "$($DatabaseName)_catalog"
        $sqlcmd = "IF NOT EXISTS(SELECT * FROM sys.fulltext_catalogs) CREATE FULLTEXT CATALOG [$catalogName] AS DEFAULT"
        Write-Message "- Running SQL command: $sqlcmd" -Diag
        $result = Invoke-SqlCommand $DatabaseName {
            $sqlCommand.CommandText = $sqlcmd
            $sqlCommand.ExecuteNonQuery()
        }
    }

    ExecuteWith-Retry $codeblock "Create full text catalog"
    Write-Message "Creating full text catalog completed successfully."
}

<#
.SYNOPSIS
    SQL script to set simple transaction log recovery mode.
#>
function Set-SimpleTransactionLogRecoveryMode()
{
    $codeblock =
    {
        $sqlcmd = "ALTER DATABASE [$DatabaseName] SET RECOVERY SIMPLE"
        Write-Message "- Running SQL command: $sqlcmd" -Diag
        $result = Invoke-SqlCommand $DatabaseName {
            $sqlCommand.CommandText = $sqlcmd
            $sqlCommand.ExecuteNonQuery()
        }
    }

    ExecuteWith-Retry $codeblock "Set simple transaction log recovery mode"
    Write-Message "Setting simple transaction log recovery mode completed successfully."
}

<#
.SYNOPSIS
    SQL script to create the database backup.
#>
function Backup-Database([string]$BackupFilePath)
{
    $codeblock =
    {
        # Backup database.
        $sqlcmd = "BACKUP DATABASE [$DatabaseName] TO Disk = N'$BackupFilePath' WITH COMPRESSION"
        Write-Message "- Running SQL command: $sqlcmd" -Diag
        $result = Invoke-SqlCommand $MasterDB {
            $sqlCommand.CommandText = $sqlcmd
            $sqlCommand.CommandTimeout = 0
            $sqlCommand.ExecuteNonQuery()
        }
    }

    ExecuteWith-Retry $codeblock "Backup database"
    Write-Message "Backup of database completed successfully."
}

<#
.SYNOPSIS
    Executes the code block with default retries.
#>
function ExecuteWith-Retry([scriptblock]$CodeBlock, [string]$BlockMessage, [int]$MaxAttempt = 5, [int]$WaitSec = 30)
{    
    Write-Message "$($BlockMessage): Starting execution with retry..." -Diag
    
    [int]$Attempt = 1
    [bool]$Completed = $false
    while ($Attempt -le $MaxAttempt -and !$Completed)
    {
        try
        {
            Invoke-Command -ScriptBlock $CodeBlock
            $Completed = $true
        }
        catch
        {
            $Message = "$($BlockMessage): Exception on attempt $($Attempt) of $($MaxAttempt): $($_.Exception.Message)"
            if ($Attempt -lt $MaxAttempt)
            {
                Write-Message $Message -Warn
                Write-Message "- $($BlockMessage): Retrying in $($WaitSec) seconds..." -Diag
                Sleep -Seconds $WaitSec
                $Attempt++
            }
            else
            {
                Write-Message $Message -Error
                throw
            }
        }
    }

    Write-Message "- $($BlockMessage): Completed execution on attempt $($Attempt) of $($MaxAttempt)." -Diag
}

[int]$ExitCode = 0
try
{
    if ($BackupFile)
    {
        if ($Restore)
        {
            Write-Message "Restoring database backup..."

            if (!(Test-Path -Path $BackupFile -PathType Leaf -ErrorAction SilentlyContinue))
            {
                throw "The backup file to restore could not be found at: $BackupFile"
            }

            Write-Message "Using specified backup file: $BackupFile"

            if ($StopDeploymentService)
            { 
                Write-Message "Stopping AX deployment..."
                Stop-AX7Deployment
            }

            # Drop the existing database and restore the database from the specified file.
            Drop-DatabaseSnapshot
            Drop-Database
            Delete-ExistingDatabaseFiles
            Create-Database
            Set-DatabaseProperties
            Restore-Database -BackupFilePath $BackupFile
            Create-DefaultFullTextCatalog
            Set-SimpleTransactionLogRecoveryMode

            if ($StartDeploymentService)
            {
                Write-Message "Starting AX deployment..."
                Start-AX7Deployment
            }

            Write-Message "Database backup successfully restored."
        }
        elseif ($Backup)
        {
            Write-Message "Creating database backup..."
            Write-Message "Using specified backup file: $BackupFile"

            # Create backup of the database to the specified file.
            Backup-Database -BackupFilePath $BackupFile

            if (!(Test-Path -Path $BackupFile -PathType Leaf -ErrorAction SilentlyContinue))
            {
                throw "Database backup failed."
            }

            Write-Message "Database backup successfully created."
        }
        else
        {
            throw "Either Backup or Restore option must be provided."
        }
    }
    else
    {
        throw "No backup file name provided."
    }
}
catch [System.Exception]
{
    Write-Message "- Exception thrown at $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())$([Environment]::NewLine)$($_.Exception.ToString())" -Diag
    Write-Message "Error in backing up or restoring the database: $($_)" -Error
    $ExitCode = -1
}
Write-Message "Script completed with exit code: $ExitCode"
Exit $ExitCode
# SIG # Begin signature block
# MIIjnAYJKoZIhvcNAQcCoIIjjTCCI4kCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAfyUaVXvXaQVUO
# 9RrlWevurcZgGIcGKzd3R9AcT+EGzKCCDYEwggX/MIID56ADAgECAhMzAAAB32vw
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
# BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgJux27UlV
# aq1fytgO7R/Tfam4LCtE+j3oJ9iOTpzWY1AwQgYKKwYBBAGCNwIBDDE0MDKgFIAS
# AE0AaQBjAHIAbwBzAG8AZgB0oRqAGGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbTAN
# BgkqhkiG9w0BAQEFAASCAQBELyXGRg3/M/CzCuUN1X+AFGTlx4NLDzdBS2NTNOIZ
# DBtIKomyPbwOGTVpOq/VeF0Awo8DgxufV5CpeVP/s8zABWY0aCw+7IrHQ6qQ2Gpv
# VecRa+ZF923EzZAKE8Rixtbt8Mh+SsmSzJ0sWmtYqKKj/syMIRWuDtaPYyb3eeuq
# lPztrUc78oUMLiNyFPm0Erf5VobVJA3q1Vx+K2HbY96vpDttRU664SghNFXxsftk
# jHM3GYXZXysxd01RD8NPW5EoekpU6xD7V+oSHOZLY2XWTxRnm1sSFu2tWmLKQ7nM
# MlytmZf5g/CNy7nWCGjwGvOZakEg4gFIIOHnDEBC47uVoYIS+zCCEvcGCisGAQQB
# gjcDAwExghLnMIIS4wYJKoZIhvcNAQcCoIIS1DCCEtACAQMxDzANBglghkgBZQME
# AgEFADCCAVkGCyqGSIb3DQEJEAEEoIIBSASCAUQwggFAAgEBBgorBgEEAYRZCgMB
# MDEwDQYJYIZIAWUDBAIBBQAEIK0iDqEnzwHfopKCDVi04rVOYRX8tvP5vXn26jFQ
# VertAgZgPQYO24wYEzIwMjEwMzAzMDMwOTU5LjY3OFowBIACAfSggdikgdUwgdIx
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
# LwYJKoZIhvcNAQkEMSIEIP4nRHn4m8z0NHBkje6FK0x1PhhoSrDtxKMFVIOeF7l9
# MIH6BgsqhkiG9w0BCRACLzGB6jCB5zCB5DCBvQQgi+vOjaqNTvKOZGut49HXrqtw
# Uj2ZCnVOurBwfgQxmxMwgZgwgYCkfjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0Eg
# MjAxMAITMwAAAT7OyndSxfc0KwAAAAABPjAiBCChpDX9KcSu9+QcwFp6NltYmc7U
# 6h6t2X9Yrm71JhU+AjANBgkqhkiG9w0BAQsFAASCAQCnVfGgMvWKP1vNJaEyLpbl
# 9ZtXP0OpL2hLqdlNhu++DX9AAnk4AV3fzXKt14b10Dmu48Im5rvXjFUihGX7U+uo
# UDTsbvEcd+T2eGtjw8zgaRokpISmpiv+mmSYgKS1V7OYWk0Tx3OqU3mwq997Sprr
# B2PrLQckoxLWXRfQ/x8w+rFGa6IO/JeWH4jU1ydV7SnzO9tfWP9ncCbPi4z8p/lI
# Sp/QbqH8vND7ie8R1fbiX9awKyPJhFS/q/e3BnGRbybcwVNAvwoRtNSS3Dripw8e
# vp3f+X58sERpAUHg9AhCEJQcOj3BU4GKXHWrQQMYYVAL49IDFP0GngD3nvdxEske
# SIG # End signature block
