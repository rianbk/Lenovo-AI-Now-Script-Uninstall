# Remediate Lenovo AI Now by performing a silent uninstall when possible.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

### Logging Setup ###
$logFolder = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs"
if (-not (Test-Path $logFolder)) { New-Item -ItemType Directory -Path $logFolder | Out-Null }
$logFile = Join-Path $logFolder "Lenovo_AI_Now_Remediate.log"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARNING","ERROR","DEBUG")] [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$timestamp [$Level] $Message"
    Write-Output $logEntry
    Add-Content -Path $logFile -Value $logEntry
}

Write-Log "=== Starting Lenovo AI Now Remediation Script ==="

$targetNamePattern = '^Lenovo AI Now\b'
$uninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
$defaultInstallPaths = @(
    'C:\Program Files\Lenovo\Lenovo AI Now',
    'C:\Program Files (x86)\Lenovo\Lenovo AI Now',
    'C:\ProgramData\Lenovo\Lenovo AI Now'
)
function Get-UninstallEntries {
    param(
        [string[]]$Roots
    )

    foreach ($root in $Roots) {
        if (-not (Test-Path -Path $root)) {
            continue
        }

        foreach ($child in Get-ChildItem -Path $root -ErrorAction SilentlyContinue) {
            try {
                $item = Get-ItemProperty -Path $child.PSPath -ErrorAction Stop
                $item | Add-Member -NotePropertyName RegistryPath -NotePropertyValue $child.PSPath -Force
                $item
            } catch {
                Write-Log "Failed to read uninstall entry at $($child.PSPath): $($_.Exception.Message)"
            }
        }
    }
}

function Get-LenovoAiNowEntries {
    Get-UninstallEntries -Roots $uninstallRoots |
        Where-Object {
            $_.PSObject.Properties['DisplayName'] -and
            $_.DisplayName -match $targetNamePattern
        }
}

function Stop-ProcessesUnderPaths {
    param(
        [string[]]$Paths,
        [string[]]$ExecutableNames,
        [int]$MaxAttempts = 5,
        [int]$DelaySeconds = 2
    )

    $normalizedPaths = $Paths |
        Where-Object { $_ } |
        ForEach-Object { $_.TrimEnd('\') } |
        Where-Object { $_ }

    $normalizedExecutables = $ExecutableNames |
        Where-Object { $_ } |
        ForEach-Object { $_.Trim().ToLowerInvariant() } |
        Select-Object -Unique

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $processes = Get-CimInstance Win32_Process -ErrorAction Stop
        } catch {
            Write-Log "Unable to enumerate processes: $($_.Exception.Message)"
            return
        }

        $targets = @()
        foreach ($process in $processes) {
            if (-not $process.Name) {
                continue
            }
            $match = $false
            $processNameLower = $process.Name.ToLowerInvariant()

            if ($normalizedExecutables -and ($normalizedExecutables -contains $processNameLower)) {
                $match = $true
            }

            if (-not $match -and $normalizedPaths) {
                $executablePath = $process.ExecutablePath
                if ($executablePath) {
                    foreach ($path in $normalizedPaths) {
                        if ($executablePath.StartsWith($path, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $match = $true
                            break
                        }
                    }
                }
            }

            if ($match) {
                $targets += $process
            }
        }

        if (-not $targets) {
            if ($attempt -eq 1) {
                Write-Log 'No Lenovo AI Now processes detected.'
            }
            break
        }

        foreach ($process in $targets | Sort-Object -Property ProcessId -Unique) {
            try {
                Write-Log "Stopping process $($process.Name) (PID $($process.ProcessId))"
                Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
            } catch {
                Write-Log "Failed to stop process $($process.Name) (PID $($process.ProcessId)): $($_.Exception.Message)"
                try {
                    Start-Process -FilePath 'taskkill.exe' -ArgumentList "/PID $($process.ProcessId) /T /F" -WindowStyle Hidden -ErrorAction Stop | Out-Null
                    Write-Log "Issued taskkill for PID $($process.ProcessId)."
                } catch {
                    Write-Log "taskkill failed for PID $($process.ProcessId): $($_.Exception.Message)"
                }
            }
        }

        Start-Sleep -Seconds $DelaySeconds
    }
}

function Stop-ServicesUnderPaths {
    param(
        [string[]]$Paths
    )

    $normalized = $Paths |
        Where-Object { $_ } |
        ForEach-Object { $_.TrimEnd('\') } |
        Where-Object { $_ }

    if (-not $normalized) {
        return
    }

    try {
        $services = Get-CimInstance Win32_Service -ErrorAction Stop
    } catch {
        Write-Log "Unable to enumerate services: $($_.Exception.Message)"
        return
    }

    foreach ($service in $services) {
        $pathName = $service.PathName
        if (-not $pathName) {
            continue
        }

        $executable = $null
        if ($pathName -match '^\s*"(?<path>[^"]+)"') {
            $executable = $matches.path
        } else {
            $segments = $pathName -split '\s+', 2
            $executable = $segments[0]
        }

        if (-not $executable) {
            continue
        }

        $matchesInstallPath = $false
        foreach ($path in $normalized) {
            if ($executable.StartsWith($path, [System.StringComparison]::OrdinalIgnoreCase)) {
                $matchesInstallPath = $true
                break
            }
        }

        if (-not $matchesInstallPath) {
            continue
        }

        if ($service.State -ne 'Running') {
            continue
        }

        try {
            Write-Log "Stopping service $($service.Name) (PID $($service.ProcessId)) with path $executable"
            Stop-Service -Name $service.Name -Force -ErrorAction Stop
        } catch {
            Write-Log "Failed to stop service $($service.Name): $($_.Exception.Message)"
        }
    }
}

function Remove-DirectoryWithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [int]$MaxAttempts = 3,
        [int]$DelaySeconds = 5
    )

    if (-not (Test-Path -Path $Path)) {
        return $true
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Write-Log "Removing directory $Path (attempt $attempt of $MaxAttempts)"
            
            # First try to take ownership and grant full permissions
            try {
                & takeown /f "$Path" /r /d y 2>&1 | Out-Null
                & icacls "$Path" /grant Administrators:F /t 2>&1 | Out-Null
            } catch {
                Write-Log "Failed to take ownership or set permissions: $($_.Exception.Message)"
            }
            
            # Try normal removal first
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            return $true
        } catch {
            Write-Log "Failed to remove directory $($Path): $($_.Exception.Message)"
            Write-Log "DEBUG: About to check if attempt $attempt < $MaxAttempts"
            if ($attempt -lt $MaxAttempts) {
                Write-Log "DEBUG: Entered attempt $attempt retry logic"
                Stop-ServicesUnderPaths -Paths @($Path)
                Stop-ProcessesUnderPaths -Paths @($Path)
                
                # Try using robocopy to delete stubborn files
                try {
                    Write-Log "DEBUG: Starting robocopy attempt"
                    $tempEmpty = Join-Path $env:TEMP "EmptyForRobocopy"
                    if (-not (Test-Path $tempEmpty)) {
                        New-Item -Path $tempEmpty -ItemType Directory -Force | Out-Null
                    }
                    
                    Write-Log "Using robocopy to forcefully remove directory contents"
                    $robocopyResult = & robocopy "$tempEmpty" "$Path" /MIR /R:0 /W:0 2>&1
                    Write-Log "DEBUG: Robocopy exit code: $LASTEXITCODE"
                    
                    # Clean up temp directory
                    Remove-Item -Path $tempEmpty -Force -ErrorAction SilentlyContinue
                    
                    # Check if directory still exists
                    if (-not (Test-Path $Path)) {
                        Write-Log "DEBUG: Robocopy successfully removed directory"
                        return $true
                    }
                    
                    # Try removing the now-empty directory
                    Write-Log "DEBUG: Attempting to remove directory after robocopy"
                    Remove-Item -Path $Path -Force -ErrorAction Stop
                    Write-Log "DEBUG: Directory removal after robocopy succeeded"
                    return $true
                } catch {
                    Write-Log "Robocopy method failed with exception: $($_.Exception.Message)"
                }
                
                # Always try the Explorer downtime approach on the second attempt
                if ($attempt -eq 2) {
                    Write-Log "DEBUG: Attempt $attempt reached, about to stop Explorer"
                    try {
                        Write-Log "Stopping Explorer for 5 seconds to release shell extension DLLs"
                        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
                        Stop-Process -Name dllhost -Force -ErrorAction SilentlyContinue
                        Start-Sleep -Seconds 3  # Wait longer for DLLs to fully unload
                        
                        Write-Log "DEBUG: Explorer stopped, attempting deletion"
                        # Try to delete the directory during the explorer-free window
                        try {
                            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
                            Write-Log "Successfully removed directory during Explorer downtime"
                            Start-Process explorer -ErrorAction SilentlyContinue
                            return $true
                        } catch {
                            Write-Log "Directory removal during Explorer downtime failed: $($_.Exception.Message)"
                        }
                        
                        # Always restart Explorer
                        Write-Log "DEBUG: Restarting Explorer"
                        Start-Process explorer -ErrorAction SilentlyContinue
                        Start-Sleep -Seconds 2  # Let Explorer fully restart
                    } catch {
                        Write-Log "Failed to stop/start Explorer: $($_.Exception.Message)"
                        # Make sure Explorer is running
                        try {
                            Start-Process explorer -ErrorAction SilentlyContinue
                        } catch {}
                    }
                }
                
                Start-Sleep -Seconds $DelaySeconds
            } else {
                # Final attempt - schedule locked files for deletion on reboot
                try {
                    Write-Log "Scheduling remaining locked files for deletion on reboot"
                    $lockedFiles = Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
                    
                    if ($lockedFiles.Count -le 5) {  # Only a few files left
                        foreach ($file in $lockedFiles) {
                            if (-not $file.PSIsContainer) {
                                try {
                                    # Try to rename first
                                    $newName = $file.FullName + ".tobedeleted"
                                    Move-Item -Path $file.FullName -Destination $newName -ErrorAction SilentlyContinue
                                    
                                    # Schedule for deletion on reboot
                                    $filePath = if (Test-Path $newName) { $newName } else { $file.FullName }
                                    Add-PendingFileDelete -FilePath $filePath
                                } catch {
                                    Write-Log "Could not schedule $($file.FullName) for deletion: $($_.Exception.Message)"
                                }
                            }
                        }
                        Write-Log "Scheduled locked files for deletion on next reboot"
                        return $true  # Consider this successful
                    }
                } catch {
                    Write-Log "Failed to schedule files for deletion: $($_.Exception.Message)"
                }
                
                return $false
            }
        }
    }
}

function Add-PendingFileDelete {
    param(
        [string]$FilePath
    )
    
    try {
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
        $regName = "PendingFileRenameOperations"
        
        # Get current pending operations
        $currentOps = @()
        try {
            $currentOps = (Get-ItemProperty -Path $regPath -Name $regName -ErrorAction SilentlyContinue).$regName
            if (-not $currentOps) { $currentOps = @() }
        } catch {
            # Property doesn't exist, create it
        }
        
        # Add new operation (rename to empty string = delete)
        $newOps = $currentOps + @("\??\$FilePath", "")
        
        # Set the registry value
        Set-ItemProperty -Path $regPath -Name $regName -Value $newOps -Type MultiString -Force
        Write-Log "Added $FilePath to pending file operations for deletion on reboot"
    } catch {
        Write-Log "Failed to add pending file operation: $($_.Exception.Message)"
    }
}

function Get-UserProfileDirectories {
    $excluded = @('All Users', 'Default', 'Default User', 'Public', 'DefaultAppPool')
    Get-ChildItem -Path 'C:\Users' -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            $name = $_.Name
            -not ($excluded -contains $name) -and
            -not $name.StartsWith('.', [System.StringComparison]::OrdinalIgnoreCase)
        }
}

function Remove-UserData {
    param(
        [string[]]$AdditionalPaths = @()
    )

    $profiles = Get-UserProfileDirectories
    $targets = @()

    foreach ($profile in $profiles) {
        $profilePath = $profile.FullName
        $profileTargets = @(
            (Join-Path -Path $profilePath -ChildPath 'AppData\Local\Lenovo\Lenovo AI Now'),
            (Join-Path -Path $profilePath -ChildPath 'AppData\Local\Lenovo\LenovoAI Now'),
            (Join-Path -Path $profilePath -ChildPath 'AppData\Local\Lenovo\AI Now'),
            (Join-Path -Path $profilePath -ChildPath 'AppData\Roaming\Lenovo\Lenovo AI Now'),
            (Join-Path -Path $profilePath -ChildPath 'AppData\Roaming\Lenovo\LenovoAI Now'),
            (Join-Path -Path $profilePath -ChildPath 'AppData\Roaming\Lenovo\AI Now')
        )
        $targets += $profileTargets
        
        # Clean user registry entries
        $userSid = $null
        try {
            $userAccount = New-Object System.Security.Principal.NTAccount($profile.Name)
            $userSid = $userAccount.Translate([System.Security.Principal.SecurityIdentifier]).Value
            
            $userRegPaths = @(
                "Registry::HKEY_USERS\$userSid\SOFTWARE\Lenovo\AI Now",
                "Registry::HKEY_USERS\$userSid\SOFTWARE\Lenovo\Lenovo AI Now",
                "Registry::HKEY_USERS\$userSid\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\Lenovo AI Now",
                "Registry::HKEY_USERS\$userSid\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\LenovoAINow"
            )
            
            foreach ($regPath in $userRegPaths) {
                if (Test-Path -Path $regPath) {
                    try {
                        Write-Log "Removing user registry key $regPath for user $($profile.Name)"
                        Remove-Item -Path $regPath -Recurse -Force -ErrorAction Stop
                    } catch {
                        Write-Log "Failed to remove user registry key $regPath : $($_.Exception.Message)"
                    }
                }
            }
        } catch {
            Write-Log "Could not resolve SID for user $($profile.Name): $($_.Exception.Message)"
        }
    }

    if ($AdditionalPaths) {
        $targets += $AdditionalPaths
    }

    foreach ($target in $targets | Where-Object { $_ } | Select-Object -Unique) {
        if (Remove-DirectoryWithRetry -Path $target) {
            continue
        }

        Write-Log "Unable to remove user data directory $target after multiple attempts." "WARNING"
    }
}

function Remove-StartMenuShortcuts {
    $shortcutRoots = @(
        'C:\ProgramData\Microsoft\Windows\Start Menu',
        'C:\ProgramData\Microsoft\Windows\Start Menu\Programs',
        'C:\Users\Public\Desktop'
    )

    foreach ($profile in Get-UserProfileDirectories) {
        $profileShortcuts = @(
            (Join-Path -Path $profile.FullName -ChildPath 'AppData\Roaming\Microsoft\Windows\Start Menu'),
            (Join-Path -Path $profile.FullName -ChildPath 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs'),
            (Join-Path -Path $profile.FullName -ChildPath 'Desktop')
        )
        $shortcutRoots += $profileShortcuts
    }

    $shortcutRoots = $shortcutRoots |
        Where-Object { $_ } |
        Select-Object -Unique

    foreach ($root in $shortcutRoots) {
        if (-not (Test-Path -Path $root)) {
            continue
        }

        try {
            $shortcuts = @()
            $shortcuts += Get-ChildItem -Path $root -Filter '*Lenovo*AI*Now*.lnk' -Recurse -ErrorAction SilentlyContinue
            $shortcuts += Get-ChildItem -Path $root -Filter '*LenovoAI*.lnk' -Recurse -ErrorAction SilentlyContinue
            $shortcuts += Get-ChildItem -Path $root -Filter '*Lenovo*AI*.lnk' -Recurse -ErrorAction SilentlyContinue
        } catch {
            Write-Log "Failed to enumerate shortcuts under $root : $($_.Exception.Message)"
            continue
        }

        foreach ($shortcut in $shortcuts) {
            try {
                Write-Log "Removing shortcut $($shortcut.FullName)"
                Remove-Item -Path $shortcut.FullName -Force -ErrorAction Stop
            } catch {
                Write-Log "Failed to remove shortcut $($shortcut.FullName): $($_.Exception.Message)"
            }
        }
    }
}

function Invoke-Uninstaller {
    param(
        [string]$FilePath,
        [string[]]$ArgumentCandidates,
        [int]$TimeoutSeconds = 300
    )

    if (-not (Test-Path -Path $FilePath)) {
        Write-Log "Uninstaller not found at $FilePath"
        return $false
    }

    $uniqueArgs = $ArgumentCandidates |
        Where-Object { $_ } |
        Select-Object -Unique

    if (-not $uniqueArgs) {
        Write-Log 'No argument candidates supplied; skipping uninstaller invocation to avoid interactive prompts.'
        return $false
    }

    foreach ($candidateArgs in $uniqueArgs) {
        $displayArgs = if ([string]::IsNullOrWhiteSpace($candidateArgs)) { '(no arguments)' } else { $candidateArgs }
        Write-Log "Attempting to run $FilePath with arguments: $displayArgs"

        try {
            $process = Start-Process -FilePath $FilePath -ArgumentList $candidateArgs -PassThru -WindowStyle Hidden
        } catch {
            Write-Log "Failed to launch uninstaller: $($_.Exception.Message)"
            continue
        }

        try {
            $exited = $process.WaitForExit($TimeoutSeconds * 1000)
        } catch {
            Write-Log "Error waiting for uninstaller to exit: $($_.Exception.Message)"
            $exited = $false
        }

        if (-not $exited) {
            Write-Log "Uninstaller did not exit within $TimeoutSeconds seconds. Terminating process."
            try {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
            } catch {
                Write-Log "Failed to terminate uninstaller process: $($_.Exception.Message)"
            }
            continue
        }

        Write-Log "Uninstaller exited with code $($process.ExitCode)"
        if ($process.ExitCode -eq 0) {
            return $true
        }
    }

    return $false
}

function Invoke-MsiUninstall {
    param(
        [string]$UninstallCommand
    )

    if ($UninstallCommand -notmatch '(?i)msiexec\.exe') {
        return $false
    }

    if ($UninstallCommand -match '{[0-9A-Fa-f-]+}') {
        $productCode = $matches[0]
    } else {
        Write-Log "MSI uninstall string detected but product code missing. Raw command: $UninstallCommand"
        return $false
    }

    $arguments = "/x $productCode /qn /norestart"
    Write-Log "Invoking MSI uninstall: msiexec.exe $arguments"
    try {
        $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -PassThru -WindowStyle Hidden
        $exited = $process.WaitForExit(300 * 1000)
        if (-not $exited) {
            Write-Log 'MSI uninstall timed out after 300 seconds.'
            try {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
            } catch {
                Write-Log "Failed to terminate MSI process: $($_.Exception.Message)"
            }
            return $false
        }

        Write-Log "MSI uninstall exit code: $($process.ExitCode)"
        return ($process.ExitCode -eq 0)
    } catch {
        Write-Log "Failed to run msiexec: $($_.Exception.Message)"
        return $false
    }
}

function Remove-Residuals {
    param(
        [string[]]$InstallPaths,
        [string[]]$RegistryPaths
    )

    foreach ($path in $InstallPaths | Where-Object { $_ }) {
        if (-not (Test-Path -Path $path)) {
            continue
        }

        $maxAttempts = 3
        $removed = $false

        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            try {
                Write-Log "Removing residual directory $path (attempt $attempt of $maxAttempts)"
                Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
                $removed = $true
                break
            } catch {
                Write-Log "Failed to remove directory $($path): $($_.Exception.Message)"
                if ($attempt -lt $maxAttempts) {
                    Stop-ServicesUnderPaths -Paths @($path)
                    Stop-ProcessesUnderPaths -Paths @($path)
                    Start-Sleep -Seconds 5
                }
            }
        }

        if (-not $removed) {
            Write-Log "Unable to remove directory $($path) after $maxAttempts attempts." "WARNING"
        }
    }

    foreach ($regPath in $RegistryPaths | Where-Object { $_ }) {
        if (-not (Test-Path -Path $regPath)) {
            continue
        }

        try {
            Write-Log "Removing residual registry key $regPath"
            Remove-Item -Path $regPath -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Log "Failed to remove registry key $($regPath): $($_.Exception.Message)"
        }
    }
}

function Remove-LenovoAIServices {
    try {
        $services = Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object {
            $_.Name -match '(?i)lenovo.*ai.*now' -or 
            $_.Name -match '(?i)lenovoai' -or
            $_.DisplayName -match '(?i)lenovo.*ai.*now'
        }
        
        foreach ($service in $services) {
            try {
                if ($service.State -eq 'Running') {
                    Write-Log "Stopping service $($service.Name)"
                    Stop-Service -Name $service.Name -Force -ErrorAction Stop
                }
                
                Write-Log "Removing service $($service.Name)"
                $deleteResult = Start-Process -FilePath 'sc.exe' -ArgumentList "delete `"$($service.Name)`"" -WindowStyle Hidden -Wait -PassThru
                if ($deleteResult.ExitCode -ne 0) {
                    Write-Log "Service deletion returned non-zero exit code: $($deleteResult.ExitCode)"
                }
            } catch {
                Write-Log "Failed to remove service $($service.Name): $($_.Exception.Message)"
            }
        }
    } catch {
        Write-Log "Error enumerating services for removal: $($_.Exception.Message)"
    }
}

function Remove-ScheduledTasks {
    try {
        $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
            $_.TaskName -match '(?i)lenovo.*ai.*now' -or 
            $_.TaskName -match '(?i)lenovoai'
        }
        
        # Also check task actions if available
        foreach ($task in (Get-ScheduledTask -ErrorAction SilentlyContinue)) {
            try {
                $actions = $task.Actions
                if ($actions) {
                    foreach ($action in $actions) {
                        if ($action.Execute -and $action.Execute -match '(?i)lenovo.*ai.*now') {
                            $tasks += $task
                            break
                        }
                    }
                }
            } catch {
                # Skip tasks where we can't read actions
                continue
            }
        }
        
        $tasks = $tasks | Select-Object -Unique
        
        foreach ($task in $tasks) {
            try {
                Write-Log "Removing scheduled task: $($task.TaskName)"
                Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false -ErrorAction Stop
            } catch {
                Write-Log "Failed to remove scheduled task $($task.TaskName): $($_.Exception.Message)"
            }
        }
    } catch {
        Write-Log "Error enumerating scheduled tasks: $($_.Exception.Message)"
    }
}

function Unregister-LenovoAIShellExtensions {
    Write-Log 'Unregistering Lenovo AI Now shell extensions.'
    
    try {
        # Find all CLSIDs that point to Lenovo AI Now DLLs
        $clsidRoot = 'HKLM:\SOFTWARE\Classes\CLSID'
        if (Test-Path -Path $clsidRoot) {
            $lenovoClsids = Get-ChildItem -Path $clsidRoot -ErrorAction SilentlyContinue | 
                Where-Object { 
                    try {
                        $inprocServer = Get-ItemProperty -Path "$($_.PSPath)\InprocServer32" -ErrorAction SilentlyContinue
                        if ($inprocServer -and $inprocServer.'(Default)') {
                            $inprocServer.'(Default)' -match '(?i)lenovo.*ai.*now'
                        }
                    } catch {
                        $false
                    }
                }
            
            foreach ($clsid in $lenovoClsids) {
                try {
                    Write-Log "Unregistering shell extension CLSID: $($clsid.PSChildName)"
                    # Remove the CLSID registration
                    Remove-Item -Path $clsid.PSPath -Recurse -Force -ErrorAction Stop
                } catch {
                    Write-Log "Failed to unregister CLSID $($clsid.PSChildName): $($_.Exception.Message)"
                }
            }
        }
    } catch {
        Write-Log "Error unregistering shell extensions: $($_.Exception.Message)"
    }
}

function Invoke-LenovoAiNowRemediation {
    Write-Log 'Starting Lenovo AI Now remediation.'

    $entries = Get-LenovoAiNowEntries
    $installPaths = @()
    if ($entries) {
        $installPaths += ($entries | ForEach-Object {
            if ($_.PSObject.Properties['InstallLocation'] -and $_.InstallLocation) {
                $_.InstallLocation
            }
        })
    }
    $installPaths += $defaultInstallPaths
    $installPaths = $installPaths | Where-Object { $_ } | Select-Object -Unique

    foreach ($path in $installPaths) {
        Write-Log "Detected potential install path: $path"
    }

    $pathExists = $false
    foreach ($path in $installPaths) {
        if (Test-Path -Path $path) {
            $pathExists = $true
            break
        }
    }

    if (-not $pathExists -and -not $entries) {
        Write-Log -Level 'INFO' -Message "REMEDIATION SUCCESSFUL: Lenovo AI Now is already absent from the system."
        Remove-UserData
        Remove-StartMenuShortcuts
        return 0
    }

    if ($entries) {
        Write-Log 'Registry entries detected for Lenovo AI Now.'
    }

    Write-Log 'Skipping vendor uninstaller due to interactive-only experience; proceeding with manual cleanup.'

    $processExecutables = @(
        'lenovo ainow.exe',
        'lenovo ainow helper.exe',
        'lenovo ainow service.exe',
        'lenovo ainow utility.exe',
        'lenovo ainow mini.exe',
        'lenovo ainow oobe.exe',
        'lenovo ainow safetychecker.exe',
        'lenovo ainow launcher.exe',
        'lenovoainow.exe'
    )

    Stop-ServicesUnderPaths -Paths $installPaths
    Stop-ProcessesUnderPaths -Paths $installPaths -ExecutableNames $processExecutables
    Stop-ProcessesUnderPaths -Paths @() -ExecutableNames $processExecutables

    Remove-LenovoAIServices
    Unregister-LenovoAIShellExtensions
    Remove-UserData
    Remove-StartMenuShortcuts
    Remove-ScheduledTasks

    $registryPaths = @()
    if ($entries) {
        $registryPaths += $entries | ForEach-Object { $_.RegistryPath }
    }
    $registryPaths += @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Lenovo AI Now',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Lenovo AI Now',
        'HKLM:\SOFTWARE\Lenovo\AI Now',
        'HKLM:\SOFTWARE\Lenovo\Lenovo AI Now',
        'HKLM:\SOFTWARE\WOW6432Node\Lenovo\AI Now',
        'HKLM:\SOFTWARE\WOW6432Node\Lenovo\Lenovo AI Now',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\Lenovo AI Now',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\LenovoAINow'
    )
    $registryPaths = $registryPaths | Where-Object { $_ } | Select-Object -Unique

    Remove-Residuals -InstallPaths $installPaths -RegistryPaths $registryPaths

    # Final pass to ensure nothing spun back up before verification.
    Stop-ServicesUnderPaths -Paths $installPaths
    Stop-ProcessesUnderPaths -Paths $installPaths -ExecutableNames $processExecutables

    $remainingEntries = Get-LenovoAiNowEntries
    $remainingPaths = $installPaths | Where-Object { Test-Path -Path $_ }

    if ($remainingEntries -or $remainingPaths) {
        if ($remainingEntries) {
            foreach ($entry in $remainingEntries) {
                Write-Log "Residual registry entry still present: $($entry.RegistryPath)" "WARNING"
            }
        }

        if ($remainingPaths) {
            foreach ($path in $remainingPaths) {
                Write-Log "Residual directory still present: $path" "WARNING"
                
                # Try one more aggressive removal attempt
                try {
                    Write-Log "Final attempt to remove stubborn directory: $path"
                    & takeown /f "$path" /r /d y 2>&1 | Out-Null
                    & icacls "$path" /grant Everyone:F /t 2>&1 | Out-Null
                    
                    # Use PowerShell to remove read-only attributes
                    Get-ChildItem -Path $path -Recurse -Force | ForEach-Object {
                        $_.Attributes = $_.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
                    }
                    
                    Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
                    Write-Log "Successfully removed directory on final attempt: $path"
                } catch {
                    Write-Log "Final removal attempt failed for $path : $($_.Exception.Message)" "WARNING"
                }
            }
        }

        # Check again after final cleanup attempts
        $finalRemainingEntries = Get-LenovoAiNowEntries
        $finalRemainingPaths = $installPaths | Where-Object { Test-Path -Path $_ }
        
        # If we still have stubborn directories, try the Explorer downtime approach
        foreach ($stubbornPath in $finalRemainingPaths) {
            try {
                Write-Log "Attempting Explorer downtime removal for stubborn directory: $stubbornPath"
                Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
                Stop-Process -Name dllhost -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3  # Wait for DLLs to unload
                
                # Try to delete during the explorer-free window
                try {
                    Remove-Item -Path $stubbornPath -Recurse -Force -ErrorAction Stop
                    Write-Log "Successfully removed stubborn directory during Explorer downtime: $stubbornPath"
                } catch {
                    Write-Log "Explorer downtime removal failed for $stubbornPath : $($_.Exception.Message)"
                }
                
                # Always restart Explorer
                Start-Process explorer -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            } catch {
                Write-Log "Explorer downtime approach failed: $($_.Exception.Message)"
                # Make sure Explorer is running
                try {
                    Start-Process explorer -ErrorAction SilentlyContinue
                } catch {}
            }
        }
        
        # Final check after Explorer downtime attempt
        $finalRemainingEntries = Get-LenovoAiNowEntries
        $finalRemainingPaths = $installPaths | Where-Object { Test-Path -Path $_ }
        
        # Count remaining files to determine if cleanup was successful
        $totalRemainingFiles = 0
        foreach ($path in $finalRemainingPaths) {
            try {
                $fileCount = (Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer }).Count
                $totalRemainingFiles += $fileCount
                Write-Log "Directory $path contains $fileCount remaining files"
            } catch {
                Write-Log "Could not count files in $path : $($_.Exception.Message)"
            }
        }
        
        if ($finalRemainingEntries -or ($totalRemainingFiles -gt 5)) {
            Write-Log "Lenovo AI Now removal completed with significant residual items remaining." "WARNING"
            if ($finalRemainingEntries) {
                Write-Log "Remaining registry entries: $($finalRemainingEntries.Count)" "WARNING"
            }
            if ($finalRemainingPaths) {
                Write-Log "Remaining directories with $totalRemainingFiles total files: $($finalRemainingPaths -join ', ')" "WARNING"
            }
            Write-Log "Manual cleanup or system reboot may be required to complete removal." "WARNING"
            Write-Log -Level 'ERROR' -Message "REMEDIATION PARTIALLY SUCCESSFUL: Some Lenovo AI Now components could not be removed."
            return 1603  # Partial failure - some components remain
        } elseif ($totalRemainingFiles -gt 0) {
            Write-Log "Lenovo AI Now removal completed successfully. $totalRemainingFiles locked files scheduled for deletion on reboot."
            Write-Log -Level 'INFO' -Message "REMEDIATION SUCCESSFUL: Lenovo AI Now removed. Reboot recommended for complete cleanup."
            return 3010  # Success but reboot required
        }
        
        Write-Log -Level 'INFO' -Message "REMEDIATION COMPLETELY SUCCESSFUL: All Lenovo AI Now components removed."
        return 0  # Complete success
        
        return 0  # Always return success as we've done our best
    }

    Write-Log 'Lenovo AI Now successfully removed.'
    
    # Ensure Explorer is running to prevent visual glitches
    try {
        $explorerProcesses = Get-Process -Name explorer -ErrorAction SilentlyContinue
        if (-not $explorerProcesses) {
            Write-Log 'Restarting Explorer to restore desktop functionality.'
            Start-Process explorer -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Log "Warning: Could not verify Explorer status: $($_.Exception.Message)" "WARNING"
    }
    
    return 0
}

$exitCode = 0
try {
    $exitCode = Invoke-LenovoAiNowRemediation
    
    # Log final status based on exit code
    switch ($exitCode) {
        0 { 
            Write-Log -Level 'INFO' -Message "Script completed successfully with exit code $exitCode"
        }
        3010 { 
            Write-Log -Level 'INFO' -Message "Script completed with exit code $exitCode (reboot recommended)"
        }
        1603 { 
            Write-Log "Script completed with exit code $exitCode (partial failure)" "WARNING"
        }
        default { 
            Write-Log -Level 'ERROR' -Message "Script completed with unexpected exit code $exitCode"
        }
    }
} catch {
    $exitCode = 1
    Write-Log "REMEDIATION FAILED: Unhandled exception during remediation: $($_.Exception.Message)" "ERROR"
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Log $_.InvocationInfo.PositionMessage "ERROR"
    }
}

exit $exitCode
