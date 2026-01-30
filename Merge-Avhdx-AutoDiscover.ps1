<#
.SYNOPSIS
    Automatically finds VMs in the current folder and merges their AVHDX disks into base VHDX.
.DESCRIPTION
    1. Scans current directory and subfolders for VHDX/AVHDX files.
    2. Groups disks by VM (based on parent-child chains).
    3. For each VM:
       - shuts down if running;
       - merges all AVHDX into base VHDX;
       - logs results.
.EXAMPLE
    .\Merge-Avhdx-AutoDiscover.ps1
#>

# Log file
$ScriptDir = $PSScriptRoot
$LogFile = "$ScriptDir\Merge_AVHDX_Auto_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
"Script started: $(Get-Date)" | Out-File -FilePath $LogFile -Append


# 1. Find all VHDX and AVHDX in current folder and subfolders
$AllDisks = Get-ChildItem -Path $ScriptDir -Recurse -Include *.vhdx, *.avhdx -File
if ($AllDisks.Count -eq 0) {
    "ERROR: No VHDX/AVHDX files found in '$ScriptDir'." | Out-File -FilePath $LogFile -Append
    exit 1
}

# 2. Collect disk info (including ParentPath)
$DiskInfo = @()
foreach ($disk in $AllDisks) {
    try {
        $vhd = Get-VHD -Path $disk.FullName
        $DiskInfo += [PSCustomObject]@{
            Path      = $disk.FullName
            ParentPath = $vhd.ParentPath
            VhdType   = $vhd.VhdType
        }
    }
    catch {
        "WARNING: Failed to read disk '$($disk.FullName)': $_" | Out-File -FilePath $LogFile -Append
    }
}

# 3. Group disks by root VHDX (no parent)
$VmGroups = @{}
foreach ($disk in $DiskInfo) {
    # Find root disk (follow parent chain to end)
    $root = $disk.Path
    $parent = $disk.ParentPath
    while ($parent -and (Test-Path $parent)) {
        $root = $parent
        $parentInfo = Get-VHD -Path $parent -ErrorAction SilentlyContinue
        $parent = $parentInfo.ParentPath
    }

    # Add disk to group by root VHDX
    if (-not $VmGroups.ContainsKey($root)) {
        $VmGroups[$root] = @()
    }
    $VmGroups[$root] += $disk
}

# 4. Process each VM group
foreach ($rootVhd in $VmGroups.Keys) {
    $DisksInVm = $VmGroups[$rootVhd]
    $VmName = [System.IO.Path]::GetFileNameWithoutExtension($rootVhd)

    # Log VM processing start
    "Processing VM: '$VmName' (root disk: $rootVhd)" | Out-File -FilePath $LogFile -Append
    "VM disks count: $($DisksInVm.Count)" | Out-File -FilePath $LogFile -Append

    # 4.1. Check if VM exists in Hyper-V
    $Vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if ($Vm) {
        # 4.2. Shut down if running
        if ($Vm.State -eq 'Running') {
            "Shutting down VM '$VmName'..." | Out-File -FilePath $LogFile -Append
            Stop-VM -Name $VmName -Force -Confirm:$false
            while ((Get-VM -Name $VmName).State -ne 'Off') { Start-Sleep -Seconds 1 }
        }
    } else {
        "VM '$VmName' not found in Hyper-V. Proceeding with disk merge only." | Out-File -FilePath $LogFile -Append
    }

    # 4.3. Sort AVHDX by modification time (newest first)
    $AvhdxList = $DisksInVm | Where-Object { $_.VhdType -eq 'Differencing' } | Sort-Object { (Get-Item $_.Path).LastWriteTime } -Descending

    if ($AvhdxList.Count -eq 0) {
        "No AVHDX disks to merge for VM '$VmName'." | Out-File -FilePath $LogFile -Append
        continue
    }

    # 4.4. Merge each AVHDX into its parent
    foreach ($avhdx in $AvhdxList) {
        $AvhdxPath = $avhdx.Path
        $ParentPath = $avhdx.ParentPath

        "Merging '$AvhdxPath' into '$ParentPath'..." | Out-File -FilePath $LogFile -Append

        try {
            Merge-VHD -Path $AvhdxPath -Destination $ParentPath -ErrorAction Stop
            if (Test-Path $AvhdxPath) {
                "WARNING: File '$AvhdxPath' not deleted after merge." | Out-File -FilePath $LogFile -Append
            } else {
                "SUCCESS: Merged $AvhdxPath → $ParentPath" | Out-File -FilePath $LogFile -Append
            }
        }
        catch {
            "ERROR: Merge failed for '$AvhdxPath': $_" | Out-File -FilePath $LogFile -Append
        }
    }
}

# 5. Finalization
"Merge process completed. $(Get-Date)" | Out-File -FilePath $LogFile -Append
"Log saved to: $LogFile"
