Lenovo AI Now Removal Script
============================

This repository contains PowerShell scripts to detect and remove "Lenovo AI Now" a vendor-installed application often considered bloatware on Lenovo devices. These scripts are designed primarily for use with Microsoft Intune Remediation scripts, but can be adapted to other deployment tools.

Contents
--------

- **detect.ps1**  
  A detection script that checks whether Lenovo AI Now is currently installed.  
  - Exits **1** if Lenovo AI Now is found in uninstall registry entries, common install paths, or running services/processes.  
  - Exits **0** if Lenovo AI Now is not detected.

- **remediate.ps1**  
  The remediation (removal) script that:
  1. Checks if Lenovo AI Now is present (if not, exits successfully).
  2. If present, performs comprehensive cleanup: stops services/processes, removes program files, cleans registry entries, removes shortcuts, unregisters shell extensions, and removes scheduled tasks.
  3. **Cleanup Logic:**  
     - Leverages multiple functions for stubborn files: ownership changes (takeown/icacls), robocopy mirror deletion, Explorer downtime windows, and scheduling deletions for reboot when necessary.
     - Performs final verification and returns appropriate exit codes.
  4. **Exit Codes:**  
     - **0**: Complete success, all components removed.  
     - **3010**: Success, reboot recommended (locked files scheduled for deletion).  
     - **1603**: Partial failure, some residual components remain.  
     - **1**: Unhandled error during remediation.

How It Works
------------

1. **Detection**  
   - In Intune, run **detect.ps1** as the detection script.  
   - Checks uninstall registry keys (32-bit and 64-bit), common Lenovo install paths, and running services/processes matching Lenovo AI Now patterns.
   - If it exits **1**, Lenovo AI Now is present; if it exits **0**, Lenovo AI Now is not present.

2. **Remediation / Removal**  
   - When Lenovo AI Now is present, run **remediate.ps1**:
     1. Enumerates uninstall entries and install paths.
     2. Stops related services and processes.
     3. Attempts vendor uninstaller if non-interactive command available (prefers manual cleanup).
     4. Removes program files, user data, and shortcuts using escalated removal techniques.
     5. Cleans registry keys, scheduled tasks, and shell extension registrations.
     6. Re-checks for residuals and reports final status.

Deployment Scenarios
--------------------

**Intune (Platform Scripts - Recommended)**

- Upload **detect.ps1** as the Detection Script.  
- Upload **remediate.ps1** as the Remediation Script.  
- Both run under SYSTEM context by default.
- If detect.ps1 exits 1, Intune triggers remediate.ps1.

**Win32 App (Untested)**

- Can be packaged as a Win32 app for pre-provisioned devices.
- **Warning**: Win32 deployment is untested test thoroughly in a pilot environment first.

Files
-----

| File           | Description                                                                                           |
|----------------|-------------------------------------------------------------------------------------------------------|
| detect.ps1     | Checks registry, install paths, and running services/processes. Exits 1 if found, 0 if not.        |
| remediate.ps1  | Full removal script that performs comprehensive cleanup with escalated removal techniques.           |
| README.md      | This documentation.                                                                                   |

Logs & Troubleshooting
----------------------

**Log Location:**  
`C:\ProgramData\Microsoft\IntuneManagementExtension\Logs`

**Log Files:**

- `Lenovo_AI_Now_Detect.log`  
- `Lenovo_AI_Now_Remediate.log` 

**Common Scenarios:**

1. **Exit Code 3010 (Reboot Recommended)**  
   - Some files were locked and scheduled for deletion on reboot.
   - Reboot the device to complete cleanup.

2. **Exit Code 1603 (Partial Failure)**  
   - Check remediation log for WARNING/ERROR entries about residual files or registry keys.
   - May require manual cleanup or additional remediation attempts.

3. **Stubborn Components**  
   - The script uses multiple techniques including Explorer downtime and file locking workarounds.
   - For persistent issues, check the log for specific files/registry keys that couldn't be removed.

Notes & Tips
------------

1. **SYSTEM Context**  
   - Scripts are designed to run under SYSTEM context (standard for Intune platform scripts).

2. **Manual vs. Vendor Cleanup**  
   - Scripts perform manual cleanup rather than relying on interactive vendor uninstallers.

3. **Testing**  
   - Test in a pilot environment before broad deployment.
   - Monitor logs for any unexpected behavior or residual components.

