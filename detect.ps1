# Detect whether Lenovo AI Now is installed and persist the transcript/output to disk.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

### Logging Setup ###
$logFolder = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs"
if (-not (Test-Path $logFolder)) { New-Item -ItemType Directory -Path $logFolder | Out-Null }
$logFile = Join-Path $logFolder "Lenovo_AI_Now_Detect.log"

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

Write-Log "=== Starting Lenovo AI Now Detection Script ==="

$targetNamePattern = '^Lenovo AI Now\b'
$uninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
$possibleInstallPaths = @(
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
                Get-ItemProperty -Path $child.PSPath -ErrorAction Stop
            } catch {
                continue
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

function Test-LenovoServicesAndProcesses {
    try {
        # Be more specific - look for Lenovo AI Now specific services and processes
        $lenovoAiNowServices = @(Get-Service -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like '*Lenovo*AI*' -or
            $_.DisplayName -like '*Lenovo*AI*Now*' -or
            $_.Name -eq 'LenovoAINow' -or
            $_.DisplayName -eq 'Lenovo AI Now'
        })
    } catch {
        Write-Log "Warning: Could not query services: $($_.Exception.Message)" "WARNING"
        $lenovoAiNowServices = @()
    }

    try {
        # Be more specific - look for Lenovo AI Now specific processes
        $lenovoAiNowProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like '*Lenovo*AI*' -or
            $_.ProcessName -like '*Lenovo*AI*Now*' -or
            $_.Name -eq 'LenovoAINow' -or
            $_.ProcessName -eq 'LenovoAINow'
        })
    } catch {
        Write-Log "Warning: Could not query processes: $($_.Exception.Message)" "WARNING"
        $lenovoAiNowProcesses = @()
    }

    return ($lenovoAiNowServices.Count -gt 0) -or ($lenovoAiNowProcesses.Count -gt 0)
}

$exitCode = 0

try {
    Write-Log 'Starting Lenovo AI Now detection.'

    $installedViaRegistry = Get-LenovoAiNowEntries
    $servicesAndProcessesDetected = Test-LenovoServicesAndProcesses
    
    $detected = $false

    if ($installedViaRegistry) {
        foreach ($entry in $installedViaRegistry) {
            Write-Log "Detected Lenovo AI Now via registry: DisplayName='$($entry.DisplayName)', Version='$($entry.DisplayVersion)', Key='$($entry.PSChildName)'"
        }
        $detected = $true
    }

    if ($servicesAndProcessesDetected) {
        Write-Log "Detected Lenovo services and processes (Lenovo software is running)"
        $detected = $true
    }

    $pathMatch = $null
    foreach ($path in $possibleInstallPaths) {
        if (Test-Path -Path $path) {
            $pathMatch = $path
            break
        }
    }

    if ($pathMatch) {
        Write-Log "Lenovo AI Now directory present at: $pathMatch"
        $detected = $true
    }

    if ($detected) {
        Write-Log "DETECTION RESULT: Lenovo AI Now detected - remediation required." "INFO"
        $exitCode = 1
    } else {
        Write-Log "DETECTION RESULT: Lenovo AI Now not detected - no remediation needed." "INFO"
        $exitCode = 0
    }
} catch {
    $exitCode = 1
    Write-Log "DETECTION FAILED: Unhandled exception during detection: $($_.Exception.Message)" "ERROR"
    if ($_.InvocationInfo?.PositionMessage) {
        Write-Log $_.InvocationInfo.PositionMessage "ERROR"
    }
}

exit $exitCode
