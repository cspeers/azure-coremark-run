#!/usr/bin/env pwsh
#Requires -Version 7.1
[CmdletBinding()]
param
(
    [Parameter()]
    [String]$ACUHOME = $PSScriptRoot,
    [Parameter()]
    [int]$Iterations = 7,
    [Parameter()]
    [string]$COREMARK_REPO = "https://github.com/eembc/coremark.git",
    [Parameter()]
    [string[]]$ProcessesToCheck = @("CoreMark", "make", "defunct")
)

$CURRENT_DIR = $PWD
$HOSTNAME = $(hostname)
$RUNTIME = Get-date -Format "hhmmss-yyyyMMdd"

#region Setup Paths
$WORKING_DIR = Join-Path  $ACUHOME "ACUCoreMark"
$RESULTS_DIR = Join-Path $WORKING_DIR "ACUCoreMarkResults"
#Results
$RESULTS = Join-Path $RESULTS_DIR "ACU_TestResults.csv"
$TEST_RESULTS = Join-Path $RESULTS_DIR "${HOSTNAME}-${RUNTIME}.csv"

#endregion

#region Helpers

function Test-ProcessRunning {
    [CmdletBinding()]
    param
    (
        [Parameter(ValueFromPipeline = $true)]
        [string[]]$ProcessName
    )
    
    begin {
        $Result = $false
        $Processes = Get-Process
    }   
    process {
        foreach ($Process in $ProcessName) {
            $Match = $Processes | Where-Object { $_.Name -like $Process }
            if ($null -ne $Match) {
                Write-Information "$($Process.Name) is running!"
                $Result = $true
                break
            }
        }
    }
    end {
        return $Result
    }
}

function Get-ProcessorInfo {
    $CpuDetails = $(lscpu -B) | ConvertFrom-StringData -Delimiter ":"
    [int]$logicalProcessors = $CpuDetails."CPU(s)"
    [int]$coresPerSocket = $CpuDetails.'Core(s) per socket'
    [int]$socketCount = $CpuDetails.'Socket(s)'
    [int]$threadsPerCore = $CpuDetails.'Thread(s) per core'
    [int]$mhz = $CpuDetails.'CPU Mhz'
    [int]$bogoMips = $CpuDetails.'BogoMIPS'
    [string]$vendor = $CpuDetails.'Vendor ID'
    [int]$family = $CpuDetails.'CPU family'
    [int]$model = $CpuDetails.'Model'
    [string]$name = $CpuDetails.'Model name'
    [int]$stepping = $CpuDetails.'Stepping'
    [string]$virtualization = $CpuDetails.'Virtualization' ?? 'None'
    [string]$hypervisor = $CpuDetails.'Hypervisor vendor' ?? 'None'
    [int]$numaNodes = $CpuDetails.'NUMA node(s)' ?? 1
    [int]$l2Cache = $CpuDetails.'L2 cache'
    [int]$l3Cache = $CpuDetails.'L3 cache'
    
    $physicalProcessors = $socketCount * $coresPerSocket;
    if ($($physicalProcessors * $threadsPerCore) -eq $logicalProcessors) {
        $threads = $logicalProcessors
        if ($threadsPerCore -gt 1) {
            $threads = $threadsPerCore * $physicalProcessors
        }
    }
    else {
        throw "This shouldn't be possible.."
    }
    $ResultProps = [ordered]@{
        name               = $name
        logicalProcessors  = $logicalProcessors
        threads            = $threads
        physicalProcessors = $physicalProcessors
        socketCount        = $socketCount
        mhz                = $mhz
        bogoMips           = $bogoMips
        guessits           = $bogoMips * 100
        vendor             = $vendor
        model              = $model
        family             = $family
        stepping           = $stepping
        virtualization     = $virtualization
        hypervisor         = $hypervisor
        numaNodes          = $numaNodes
        l2Cache            = $l2Cache
        l3Cache            = $l3Cache

    }
    $Result = New-Object psobject -Property $ResultProps
    return $Result
}

function Get-MemorySize {
    [CmdletBinding()]
    param()
    $memSize = 'unknown'
    if ($($(free -h) -match '^Mem:\s+(\S+)\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+') -match '^Mem:\s+(\S+)\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+') {
        $memSize = $Matches[1]
    }
    return $memSize
}

function ConvertFrom-TestRun {
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory, ValueFromPipeline)]
        [string]$TestRunOutput
    )
    $buffer = @()
    $output = $null
    $memSize = Get-MemorySize
    $TestRuns = Get-Content -Path $TestRunOutput
    foreach ($line in $TestRuns) {
        if ($line -match '^Begin') {
            $buffer = @()
        }
        elseif ($line -match '^End') {
            $Parsed = @{}
            $sd = [string]::Join("`n", $buffer) | ConvertFrom-StringData -Delimiter ":"
            foreach ($kvp in $sd.GetEnumerator() ) {
                $Parsed[$kvp.Name] = $kvp.Value
            }
            #now munge the parsed values
            $props = [ordered]@{
                'Concurrency_type'   = $Parsed['Concurrency'] ?? "None";
                'Threads'            = $Parsed['Threads'] ?? 1
                'CoreMark_Size'      = $Parsed['CoreMark Size'];
                'Total_ticks'        = $Parsed['Total ticks'];
                'Total_time_secs'    = $Parsed['Total time (secs)'];
                'Iterations_per_Sec' = $Parsed['Iterations/Sec'];
                'Iterations'         = $Parsed['Iterations'];
                'Correct_operation'  = $Parsed['Correct'] ?? $false;
                'CPU_COUNT'          = $CpuDetails.logicalProcessors;
                'THREADS_PER_CORE'   = $CpuDetails.threads; 
                'NUMA_NODE_COUNT'    = $CpuDetails.numaNodes;
                'MODEL_NAME'         = $CpuDetails.name;
                'HYPERVISOR_VENDOR'  = $CpuDetails.hypervisor;
                'L2_CACHE'           = $CpuDetails.l2Cache; 
                'L3_CACHE'           = $CpuDetails.l3Cache;
                'MEMORY_SIZE'        = $memSize ?? 'Unknown';
            }
            $output = New-Object psobject -Property $props
        }
        else {
            if (-not [string]::IsNullOrEmpty($line)) {
                if ($line -like "*:*") {
                    $buffer += $line
                }
                elseif ($line -match '^Correct operation validated. ') {
                    $buffer += "Correct:true"
                }
                elseif ($line -match '^Parallel *(\S+) *: (\d+)') {
                    $buffer += "Concurrency:$($Matches[1])"
                    $buffer += "Threads:$($Matches[2])"
                }
            }
        }
    }
    if ($null -eq $output) {
        throw "Unable to convert $TestRunOutput"
    }
    return $output
}

function Start-Build {
    param
    (
        [Parameter(Mandatory)]
        [string[]]$MakeArgs,
        [Parameter(Mandatory)]
        [string]$StdOut,
        [Parameter(Mandatory)]
        [string]$StdErr,
        [Parameter()]
        [string]$TempPath = '/tmp'
    )
    $StoTemp = Join-Path $TempPath "stdOut.log"
    $SteTemp = Join-Path $TempPath "stdErr.log"
    Write-Information "Building with $([string]::Join(' ',$MakeArgs))"
    $Result = Start-Process make -ArgumentList $MakeArgs `
        -RedirectStandardError $SteTemp -RedirectStandardOutput $StoTemp `
        -Wait -PassThru
    Get-Content $StoTemp | Add-Content $StdOut
    Get-Content $SteTemp | Add-Content $StdErr
    if ($Result.ExitCode -ne 0) {
        Write-Error "make exited with $($Result.ExitCode)"
    }
    Remove-Item -Path $StoTemp, $SteTemp -Force -ErrorAction SilentlyContinue
}

function Start-MakeCMFromSource {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$localRepoDir,
        [Parameter(Mandatory)]
        [string]$LogDir,
        [Parameter(Mandatory)]
        [string]$OutDir,
        [Parameter(Mandatory)]
        [int]$Threads,
        [Parameter(Mandatory)]
        [string]$RepoUrl
    )
    if (Test-Path $localRepoDir) {
        Write-Verbose "Changing directory to ${localRepoDir}"
        Set-Location $localRepoDir
        git reset --hard | Out-Null
        git pull | Out-Null
    }
    else {
        Write-Verbose "$localRepoDir already exists, pulling..."
        git clone $RepoUrl
        Write-Verbose "Changing directory to ${localRepoDir}"
        Set-Location $localRepoDir   
    }

    #build CoreMark
    $cti = "PTHREAD"
    if ($Threads -lt 10) {
        $zfcci = "0$Threads"
    }
    else {
        $zfcci = "$Threads"
    }
    $buildExe = 'coremark.exe'
    $NewExeName = "coremark.$zfcci.$cti.exe"
    $CMEXE = Join-Path $OutDir $NewExeName
    $CBE = Join-Path $LogDir "CoreMark_Make.$zfcci.$cti.Build.stderr"
    $CBO = Join-Path $LogDir "CoreMark_Make.$zfcci.$cti.Build.stdout"

    #modify the port make args
    $PortMePath = Join-Path $localRepoDir 'posix/core_portme.mak'
    $PortMeMak = Get-Content -Path $PortMePath
    $PortMeMak -replace '^LFLAGS_END \+=.*$', 'LFLAGS_END += -lrt -lpthread' | Set-Content -Path $PortMePath
    #make it
    $MakeArgs = @("clean", "PORT_DIR=simple")
    Start-Build $MakeArgs -StdOut $CBO -StdErr $CBE
    $XCFLAGS = "-DMULTITHREAD=$Threads -DUSE_$cti=1"
    $MakeArgs = @("XCFLAGS=`"$XCFLAGS`"", "PORT_DIR=linux")
    Start-Build $MakeArgs -StdOut $CBO -StdErr $CBE -TempPath $LogDir
    Write-Verbose "Copying run1.log,run2.log -> ${LogDir}"
    Get-ChildItem -Path $localRepoDir -Filter "run*.log" | Move-Item -Destination $OutDir -Force
    Write-Verbose "Copying ${buildExe} -> ${CMEXE}"
    Get-Item $buildExe | Move-Item -Destination $OutDir -PassThru | Rename-Item -NewName $NewExeName
    chmod +x $CMEXE
    return $CMEXE
}

function Confirm-Paths {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $MainPath,
        [Parameter()]
        [string]
        $ResultPath,        
        [Parameter()]
        $BinPath = 'tbin'
    )
    $THOME = Join-Path $MainPath "acu"
    $TBIN = Join-Path $THOME $BinPath
    #directory creation:
    if (Test-Path $ResultPath) {
        Get-ChildItem -Path $ResultPath -Filter '*.std*' | Remove-Item
        Write-Verbose "Deleted existing logs in $ResultPath..."
    }
    else {
        New-Item -Path $ResultPath -ItemType Directory -Force | Out-Null
        Write-Verbose "Created $ResultPath"
    }
    if (Test-Path $THOME) {
        if (Test-Path $TBIN) {
            Remove-Item -Path $TBIN -Recurse -Force
        }
    }
    New-Item -Path $TBIN -ItemType Directory -Force | Out-Null
    Write-Verbose "Created $THOME"
    return $THOME
}

#endregion

try {

    if ($ProcessesToCheck | Test-ProcessRunning) {
        Write-Error "FATAL:  Processes in memory may taint tests.  Exiting."
    }    
    Write-Information "Starting ACU Coremark Run on ${HOSTNAME} (x$Iterations) - $(Get-Date) Working Dir:${ACUHOME} -> ${TOUT}"
    $CTE = Join-Path $RESULTS_DIR "CoreMarkTest.stderr"
    $CTO = Join-Path $RESULTS_DIR "CoreMarkTest.stdout"
    $StoTemp = Join-Path $RESULTS_DIR "stdOut.log"
    $SteTemp = Join-Path $RESULTS_DIR "stdErr.log"
    
    $THOME = Confirm-Paths -MainPath $WORKING_DIR -ResultPath $RESULTS_DIR
    $TBIN = Join-Path $THOME "tbin"
    $CpuDetails = Get-ProcessorInfo
    #clone the CoreMark repo
    Set-Location -Path $THOME
    $RepoName = ($COREMARK_REPO.Split('/') | Select-Object -Last 1).Split('.') | Select-Object -First 1
    $repoDir = Join-Path $THOME  $RepoName
    #build CoreMark
    $CMEXE = Start-MakeCMFromSource -localRepoDir $repoDir -Threads $CpuDetails.threads `
        -LogDir $RESULTS_DIR -OutDir $TBIN -RepoUrl $COREMARK_REPO

    #run test iterations
    Write-Information "Running $Iterations Iterations"
    #Build and Run Log Files
    $TestArgs = @('0x3415', '0x3415', '0x66', $CpuDetails.guessits, 7, 1, 2000)
    for ($i = 0; $i -lt $Iterations; $i++) {
        Write-Information "Starting Test Pass #$($i+1)"
        Add-Content -Path $CTE -Value "Begin Run for $exe at $(Get-date):`n"
        Add-Content -Path $CTO -Value "Begin Run for $exe at $(Get-date):`n"
        Add-Content -Path $CTO -Value "Cmd used for tests by hand:  $CMEXE $([string]::Join(' ',$TestArgs))"        
        $TestRun = Start-Process -FilePath $CMEXE -ArgumentList $TestArgs `
            -RedirectStandardOutput $StoTemp -RedirectStandardError $SteTemp `
            -Wait -PassThru
        Get-Content $SteTemp | Add-Content -Path $CTE
        Get-Content $StoTemp | Add-Content -Path $CTO
        Add-Content -Path $CTE -Value "End of Run for $exe at $(Get-date).`n"
        Add-Content -Path $CTO -Value "End of Run for $exe at $(Get-date).`n"
        if ($TestRun.ExitCode -ne 0) {
            Write-Error "${CMEXE} failed with $($TestRun.ExitCode)"
        }
    }

    #munge the results
    if (Test-Path $CTO) {
        $Result = ConvertFrom-TestRun -TestRunOutput $CTO
        $Result | Export-Csv -Path $TEST_RESULTS
        #Also append it to any existing one...
        $Result | Export-Csv -Path $RESULTS -Append:$(Test-Path $RESULTS)
        Write-Information "${HOSTNAME} completed $(Get-Date) - see ${RESULTS}"
        Write-Output $Result
    }
}
finally {
    Set-Location -Path $CURRENT_DIR
    Remove-Item -Path $StoTemp, $SteTemp -Force -ErrorAction SilentlyContinue
}
