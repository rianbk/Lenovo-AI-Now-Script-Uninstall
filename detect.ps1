[CmdletBinding()]
param()

$ErrorActionPreference = "SilentlyContinue"
$fileThreshold = 5

Write-Host "=== Lenovo AI Now Detection Script ==="

$foundRegistry = $false
$totalFiles = 0
$binaryMatches = @()
$processMatches = @()
$serviceMatches = @()

$targetNamePattern = '*Lenovo AI Now*'
$registryRoots = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
)

Write-Host "Checking registry entries..."
foreach ($root in $registryRoots) {
    if (-not (Test-Path $root)) {
        Write-Host "Registry path not found: $root"
        continue
    }

    Get-ChildItem -Path $root -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $displayName = $_.GetValue('DisplayName')
            if ($displayName -and ($displayName -like $targetNamePattern)) {
                Write-Host "Detected registry entry: $displayName"
                $foundRegistry = $true
            }
        } catch {
            # ignore entries that cannot be read
        }
    }
}

$installRoots = @(
    "C:\Program Files\Lenovo\Lenovo AI Now",
    "C:\Program Files (x86)\Lenovo\Lenovo AI Now",
    "C:\ProgramData\Lenovo\Lenovo AI Now"
)

$candidateExecutables = @(
    'LenovoAINow.exe',
    'Lenovo AI Now.exe',
    'Lenovo AI Now Helper.exe',
    'Lenovo AI Now Service.exe',
    'Lenovo AI Now Utility.exe',
    'Lenovo AI Now Mini.exe',
    'Lenovo AI Now OOBE.exe',
    'Lenovo AI Now SafetyChecker.exe',
    'Lenovo AI Now Launcher.exe'
)

Write-Host "Checking installation directories..."
foreach ($root in $installRoots) {
    if (Test-Path $root) {
        $files = Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue
        $fileCount = $files.Count
        Write-Host "Directory found: $root - File count: $fileCount"
        $totalFiles += $fileCount

        foreach ($exe in $candidateExecutables) {
            $exePath = Join-Path $root $exe
            if (Test-Path $exePath) {
                Write-Host "Detected Lenovo AI Now binary: $exePath"
                $binaryMatches += $exePath
            }
        }
    } else {
        Write-Host "Directory not found: $root"
    }
}

Write-Host "Checking for Lenovo AI Now processes..."
try {
    $running = Get-Process -ErrorAction SilentlyContinue
    foreach ($proc in $running) {
        $name = $proc.Name
        if (-not $name) { continue }
        $nameLower = $name.ToLowerInvariant()
        if ($nameLower -in @(
            'lenovoainow',
            'lenovo ainow',
            'lenovo ainow helper',
            'lenovo ainow service',
            'lenovo ainow utility',
            'lenovo ainow mini',
            'lenovo ainow oobe',
            'lenovo ainow safetychecker',
            'lenovo ainow launcher'
        )) {
            Write-Host "Detected running process: $name (PID $($proc.Id))"
            $processMatches += $name
        }
    }
} catch {
    Write-Host "Could not enumerate processes: $($_.Exception.Message)"
}

Write-Host "Checking for Lenovo AI Now services..."
try {
    $services = Get-CimInstance Win32_Service -ErrorAction Stop
    foreach ($svc in $services) {
        $displayName = $svc.DisplayName
        $serviceName = $svc.Name
        $pathName = $svc.PathName

        $nameMatch = ($displayName -and ($displayName -like 'Lenovo AI Now*')) -or
                     ($serviceName -and ($serviceName -like 'LenovoAINow*'))

        $pathMatch = $false
        if (-not $nameMatch -and $pathName) {
            $exePath = $null
            if ($pathName -match '^\s*"(?<p>[^\"]+)"') {
                $exePath = $matches.p
            } else {
                $exePath = ($pathName -split '\s+',2)[0]
            }

            if ($exePath) {
                foreach ($root in $installRoots) {
                    if ($exePath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $pathMatch = $true
                        break
                    }
                }
            }
        }

        if ($nameMatch -or $pathMatch) {
            Write-Host "Detected Lenovo AI Now service: $serviceName ($displayName)"
            $serviceMatches += $serviceName
        }
    }
} catch {
    Write-Host "Could not enumerate services: $($_.Exception.Message)"
}

Write-Host "Total Lenovo AI Now file count: $totalFiles"

$shouldRemediate = $false
if ($foundRegistry) { Write-Host "Registry traces detected."; $shouldRemediate = $true }
if ($binaryMatches.Count -gt 0) { Write-Host "Lenovo AI Now binaries detected."; $shouldRemediate = $true }
if ($processMatches.Count -gt 0) { Write-Host "Lenovo AI Now processes are running."; $shouldRemediate = $true }
if ($serviceMatches.Count -gt 0) { Write-Host "Lenovo AI Now services detected."; $shouldRemediate = $true }
if ($totalFiles -gt $fileThreshold) { Write-Host "File count exceeds threshold ($fileThreshold)."; $shouldRemediate = $true }

if ($shouldRemediate) {
    Write-Host "Lenovo AI Now detected - remediation required."
    Write-Host "Exit Code 1"
    exit 1
}

if ($totalFiles -gt 0) {
    Write-Host "Residual Lenovo AI Now files detected ($totalFiles files), but below threshold."
    Write-Host "Exit Code 0"
    exit 0
}

Write-Host "No Lenovo AI Now detected."
Write-Host "Exit Code 0"
exit 0
