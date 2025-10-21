# --- Configuration ---
$outputDirectory = "C:\Videos\Processed"
$ffprobePath = "ffprobe"
$ffmpegPath = "ffmpeg"
$cpuPreset = "medium"
$cpuCrf = 24
$cpuThreads = 6
$gpuPreset = "medium"
$gpuQuality = 25
$gpuLookAhead = 1

# --- Script Variables ---
$inputQueue = [System.Collections.Generic.Queue[string]]::new()
$cpuProcess = $null
$gpuProcess = $null
$script:activeProcessCount = 0
$VerbosePreference = "Continue"
$debugKeepWindowOpen = $true
$LogLevel = "warning" # DEFAULT VALUE
$debugWindowStyle = "Minimized" # or Normal if you want to see the output

# --- P/Invoke Definitions ---
$script:KeepAwakeAvailable = $true
try {
    Add-Type -TypeDefinition @"
    using System;
    using System.Runtime.InteropServices;
    public static class Kernel32 {
        [FlagsAttribute]
        public enum ExecutionState : uint {
            ES_AWAYMODE_REQUIRED = 0x00000040,
            ES_CONTINUOUS = 0x80000000,
            ES_DISPLAY_REQUIRED = 0x00000002,
            ES_SYSTEM_REQUIRED = 0x00000001,
            ES_NONE = 0
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        public static extern ExecutionState SetThreadExecutionState(ExecutionState esFlags);
    }
"@ -ErrorAction Stop
    Write-Verbose "Kernel32 P/Invoke type added successfully."
} catch {
    Write-Warning "⚠️ Failed to add P/Invoke type for SetThreadExecutionState. Keep-awake functionality will be disabled. Error: $($_.Exception.Message)"
    $script:KeepAwakeAvailable = $false
}
# --- End P/Invoke Definitions ---

# --- Helper Functions ---

function Get-ValidStreamMap {
    param (
        [string]$InputFile
    )

    $ffprobe = "ffprobe"
    $streamMap = ""

    # Get stream info using ffprobe
    $json = & $ffprobe -v quiet -print_format json -show_streams "$InputFile" | ConvertFrom-Json

    foreach ($stream in $json.streams) {
        switch ($stream.codec_type) {
            "video" {
                if (-not $streamMap.Contains("-map 0:v:0")) {
                    $streamMap += "-map 0:v:0 "
                }
            }
            "audio" {
                if (-not $streamMap.Contains("-map 0:a:0")) {
                    $streamMap += "-map 0:a:0 "
                }
            }
            "subtitle" {
                # Optional: Uncomment to include subtitle streams
                # $index = $stream.index
                # $streamMap += "-map 0:s:$index "
            }
        }
    }

    return $streamMap.Trim()
}


function Test-FFExecutable {
    param([string]$commandPath)
    $exec = Get-Command $commandPath -ErrorAction SilentlyContinue
    if (-not $exec) {
        Write-Error "Required command '$commandPath' not found. Ensure FFmpeg/FFprobe is installed and in your system's PATH, or update the script variables `$ffprobePath`/`$ffmpegPath`."
        return $false
    }
    Write-Verbose "Found executable: $($exec.Source)"
    return $true
}

# Finds the *stream index* (e.g., "3") with attached_pic disposition
function Get-AttachedThumbnailStreamIndex {
    param(
        [string]$inputFile,
        [string]$localFfprobePath # Pass path explicitly
    )
    try {
        # *** MODIFIED ffprobe command ***
        # Ask for index, codec_type, AND attached_pic disposition for ALL streams.
        $ffprobeOutput = & $localFfprobePath -v error -show_entries stream=index,codec_type:stream_disposition=attached_pic -of csv=p=0 "$inputFile"
        # Output might be like:
        # 0,video,0       (Stream 0, type video, attached_pic false)
        # 1,audio,0       (Stream 1, type audio, attached_pic false)
        # 2,data,1        (Stream 2, type data, attached_pic true <-- POTENTIAL PROBLEM if selected)
        # 3,video,1       (Stream 3, type video, attached_pic true <-- THIS is what we want)

        Write-Verbose "Probing '$inputFile' for attached video thumbnail streams. Raw ffprobe output:`n$ffprobeOutput"

        foreach ($line in ($ffprobeOutput -split "[\r\n]" | Where-Object { $_ -ne '' })) {
            $parts = $line.Trim() -split ','
            # Check if we have 3 parts AND the codec_type is 'video' AND the attached_pic flag is '1'
            if ($parts.Count -eq 3 -and $parts[1].Trim() -eq 'video' -and $parts[2].Trim() -eq '1') {
                $streamIndex = $parts[0].Trim()
                Write-Verbose "Found suitable attached VIDEO thumbnail stream (Index: $streamIndex, Type: $($parts[1].Trim()), AttachedPic: $($parts[2].Trim())) for '$inputFile'"
                return $streamIndex # Return the first suitable index found
            } else {
                 # Log why a potential candidate was rejected (optional but helpful for debugging)
                 if ($parts.Count -eq 3 -and $parts[2].Trim() -eq '1') {
                     Write-Verbose "Found stream with attached_pic=1 (Index: $($parts[0].Trim())) but it's not a video stream (Type: $($parts[1].Trim())). Skipping."
                 }
            }
        }
        Write-Verbose "No stream qualifying as an attached VIDEO thumbnail (type=video AND disposition=attached_pic) found via ffprobe for '$inputFile'."
        return $null
    } catch {
        Write-Warning "⚠️ Failed to probe for thumbnail stream index in '$inputFile'. Error: $($_.Exception.Message)"
        Write-Warning "Raw ffprobe output during error (if any):`n$ffprobeOutput" # Log output on error
        return $null
    }
}

# *** NEW Helper Function ***
# Finds the stream index that is BOTH MJPEG codec AND has attached_pic disposition
function Get-MjpegThumbnailStreamIndex {
    param(
        [string]$inputFile,
        [string]$localFfprobePath # Pass path explicitly
    )
    try {
        # Ask for index, codec_name, and attached_pic disposition for ALL streams.
        $ffprobeOutput = & $localFfprobePath -v error -show_entries stream=index,codec_name:stream_disposition=attached_pic -of csv=p=0 "$inputFile"
        # Output example:
        # 0,hevc,0
        # 1,aac,0
        # 3,mjpeg,1  <-- Target line: index=3, codec=mjpeg, attached_pic=1

        Write-Verbose "Probing '$inputFile' for MJPEG thumbnail stream..."
        foreach ($line in ($ffprobeOutput -split "[\r\n]" | Where-Object { $_ -ne '' })) {
            $parts = $line.Trim() -split ','
            # Check if we have 3 parts, codec is 'mjpeg', and attached_pic is '1'
            if ($parts.Count -eq 3 -and $parts[1].Trim() -eq 'mjpeg' -and $parts[2].Trim() -eq '1') {
                $streamIndex = $parts[0].Trim()
                Write-Verbose "Found MJPEG thumbnail stream at index: $streamIndex"
                return $streamIndex # Return the index of the first match
            }
        }
        # If loop finishes without finding a match
        Write-Verbose "No stream found with BOTH codec='mjpeg' AND disposition='attached_pic'."
        return $null
    } catch {
        Write-Warning "⚠️ Failed to probe for MJPEG thumbnail stream in '$inputFile'. Error: $($_.Exception.Message)"
        return $null # Assume no suitable thumbnail on error
    }
}


function Start-FFmpegProcess {
    param (
        [string]$inputFile,
        [string]$outputDir,
        [string]$mode, # "cpu" or "gpu"
        [string]$localFfmpegPath,
        [string]$localFfprobePath
    )

    # --- Input File and Output Path Checks ---
    # --- Input/Output Setup ---
    if (-not (Test-Path $inputFile -PathType Leaf)) { Write-Warning "... Skipping '$inputFile' (not found)."; return $null }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($inputFile)
    $safeBase = $base -replace '[\\/:*?"<>|]','_' -replace '\p{C}', ''
    $outputSubDir = Join-Path -Path $outputDir -ChildPath $mode.ToUpper()
    $outFile = Join-Path -Path $outputSubDir -ChildPath "$safeBase ($mode).mp4"
    if (-not (Test-Path $outputSubDir -PathType Container)) { try { New-Item -Path $outputSubDir -ItemType Directory -Force -ErrorAction Stop | Out-Null } catch { Write-Error "... Failed to create '$outputSubDir'."; return $null } }
    if (Test-Path $outFile) { Write-Warning "⏩ Skipping file as Output file exists: $outFile ... "; return $null }
    # --- End Setup ---

    # --- Inside the Start-FFmpegProcess function ---

    # (...) other parts of the function (...)
    # --- Thumbnail Handling (Initialized but Logic Commented Out By User Request) ---
    $thumbArgs = @() # Initialize $thumbArgs as empty array - CRITICAL
    Write-Verbose "Thumbnail auto-detection logic is currently actived by Start-FFmpegProcess."
    
    # Logic to find and populate $thumbArgs would go here if re-enabled
    $mjpegThumbIndex = Get-MjpegThumbnailStreamIndex -inputFile $inputFile -localFfprobePath $localFfprobePath
    if ($mjpegThumbIndex -ne $null) {
        Write-Verbose "Found MJPEG thumbnail at index $mjpegThumbIndex. Would add arguments to COPY."
        $thumbArgs = "-map" , $mjpegThumbIndex , "-c:$mjpegThumbIndex", "copy", "-disposition:$mjpegThumbIndex", "attached_pic"
        # $thumbArgs = "-c:v:1", "copy", "-disposition:v:1", "attached_pic"
    } else {
        Write-Verbose "No specific MJPEG thumbnail stream found."
    }
    
    # --- End Thumbnail ---

    # --- *** SIMPLIFIED ARGUMENT ASSEMBLY *** ---
    # Start with mandatory base args
    $ffmpegArgs = @(
        "-hide_banner",
        "-loglevel", $logLevel, # Use debug log level variable
        "-stats"
    )

    $mapArgs = Get-ValidStreamMap -InputFile $inputFile


    # Add settings and output stream codecs based on mode
    if ($mode -eq "cpu") {
        $jobDescription = "CPU ($cpuPreset / CRF $cpuCrf)"
        Write-Host "▶️ Starting CPU process for: $base" -ForegroundColor Cyan
        $ffmpegArgs += @(
            "-i", "`"$inputFile`"",  # Input File
            "$mapArgs", "-map_metadata", "0"
            "-movflags", "+faststart",
            # "-c:a:0", "copy"
            "-c:a:0", "aac", "-q:a:0", "3", # Audio Codec
            "-c:s", "copy",
            "-c:v:0", "libx265", "-preset", $cpuPreset, "-crf", $cpuCrf, "-tag:v:0", "hvc1", # Video Codec
            "-x265-params", "bframes=7:keyint=250",
            "-threads", $cpuThreads
        )
    } elseif ($mode -eq "gpu") {
        $jobDescription = "GPU (QSV $gpuPreset / Q $gpuQuality)"
        Write-Host "▶️ Starting GPU process for: $base" -ForegroundColor DarkCyan
        $ffmpegArgs += @(
            "-hwaccel", "cuda", "-hwaccel_output_format", "cuda",
            "-i", "`"$inputFile`"",  # Input File
            "$mapArgs", "-map_metadata", "0",
            "-movflags", "+faststart",
            "-c:v:0", "hevc_nvenc", "-preset:v", $gpuPreset, "-tag:v:0", "hvc1",
            "-profile:v:0", "main",
            "-tier:v", "high",
            "-rc:v", "vbr", "-cq:v", $gpuQuality,
            "-g", "250", "-bf", "3",  # NVENC allows max 3 B-frames in HEVC
            "-c:a:0", "aac", "-q:a:0", "3", # Audio Codec
            "-c:s", "copy"
        )
    } else { Write-Error "Invalid Mode"; return $null }

    # Add Mapping args
    # $ffmpegArgs += @("-map", "0", "-map_metadata", "0")

    # Add Thumbnail arguments IF they exist


    # Add Output file path LAST
    $ffmpegArgs += "`"$outFile`""
    # --- *** END SIMPLIFIED ARGUMENT ASSEMBLY *** ---

    # --- Start Process ---
    $workingDir = Split-Path $localFfmpegPath -Parent
    $startProcessArgs = @{
        FilePath            = $localFfmpegPath
        ArgumentList        = $ffmpegArgs # Use the directly assembled array
        PassThru            = $true
        WindowStyle         = $debugWindowStyle #'Normal' # Use Normal if debugging window
        WorkingDirectory    = $workingDir
        # NO LONGER Redirecting Error - remove if still present
        # RedirectStandardError = $errorLogPath
    }

    # --- Debug: Keep Window Open? ---
    # This part requires running ffmpeg indirectly via cmd.exe /k
    $finalExecutor = $localFfmpegPath
    $finalArgs = $ffmpegArgs

    if ($keepWindow) {
        Write-Warning "DEBUG: Configured to keep FFmpeg window open on error/completion."
        # We need to wrap the call in 'cmd /k' to keep the window
        # Escape quotes within the command for cmd.exe
        $cmdArgs = $ffmpegArgs | ForEach-Object {
            # Simple quote escaping for paths, might need refinement for complex args
            if ($_ -like '* *') { "`"$_`"" } else { $_ }
        }
        $cmdCommand = "`"$localFfmpegPath`"" + " " + ($cmdArgs -join ' ')

        $finalExecutor = "cmd.exe"
        # /k keeps window open AFTER command finishes (or errors)
        # Add quotes around the whole ffmpeg command for cmd.exe
        $finalArgs = "/k", $cmdCommand

        # Adjust Start-Process args for cmd.exe
        $startProcessArgs.FilePath = $finalExecutor
        $startProcessArgs.ArgumentList = $finalArgs
        $startProcessArgs.WindowStyle = 'Normal' # Need to see the window
    }
    # --- End Debug ---

    Write-Verbose "Attempting to start $mode process ($jobDescription)..."
    $commandString = "$($startProcessArgs.FilePath) $($startProcessArgs.ArgumentList -join ' ')" # Log the actual command being run
    Write-Verbose " Cmd: $commandString"

    $process = $null
    try {
        # Use the potentially modified executor/args
        $process = Start-Process @startProcessArgs -ErrorAction Stop

        if ($process -ne $null -and $process -is [System.Diagnostics.Process]) {
            # If using cmd /k, the $process object is for cmd.exe, not ffmpeg directly
            # We might lose direct ffmpeg PID tracking here, but the window stays open
            $script:activeProcessCount++; Write-Verbose " Started Process (PID $($process.Id)) ($mode)."

            # Setting title on cmd.exe window is less reliable/useful
            # Start-Sleep -Milliseconds 200; try { ... } catch {}

            # If NOT keeping window open, return the direct ffmpeg process
            # If keeping window open, we might return the cmd process
            # The monitoring loop needs to handle this (cmd exiting means ffmpeg finished)
        } else { Write-Error "Start-Process failed to return valid Process. Got: '$process'"; $process = $null }
    } catch { Write-Error "Start-Process Error: $($_.Exception.Message)"; Write-Error " Cmd: $commandString"; $process = $null }

    return $process
} # End Function Start-FFmpegProcess


# --- Ensure the rest of the script (Helper functions like Get-AttachedThumbnailStreamIndex, Manage-And-Start-WorkerProcess, Main loop) is present and uses this corrected function ---


# Function to check a worker slot, clean up if finished, and start a new process
# Function Manage-And-Start-WorkerProcess (Robust Type Check)
function Manage-And-Start-WorkerProcess {
    param(
        [ref]$processVariable,
        [System.Collections.Generic.Queue[string]]$theQueue,
        [string]$mode,
        [string]$localOutputDirectory,
        [string]$localFfmpegPath,
        [string]$localFfprobePath
    )

    # --- Part 1: Check and Cleanup Finished Process ---
    # *** FIX: Check if the variable actually holds a Process object ***
    if ($processVariable.Value -ne $null -and $processVariable.Value -is [System.Diagnostics.Process]) {
        # It's a process object, proceed safely
        $currentProcess = $processVariable.Value
        $processId = -1 # Default invalid ID
        $processNameBase = "PID Unknown" # Default name
        $processHasExited = $false

        try {
            # Get ID safely first
            $processId = $currentProcess.Id
            $processNameBase = "PID $processId" # Update default name

            # Try to get Title safely
             try {
                 $currentProcess.Refresh()
                 if ($currentProcess.MainWindowTitle) { $processNameBase = $currentProcess.MainWindowTitle }
             } catch { Write-Verbose "Could not get MainWindowTitle for $processNameBase" }

             # Now check for exit status
             if ($currentProcess.WaitForExit(10)) { $processHasExited = $true }
             else {
                $currentProcess.Refresh()
                if ($currentProcess.HasExited) { $processHasExited = true }
             }
        } catch [System.InvalidOperationException] {
             Write-Verbose "Process handle for '$processNameBase' likely invalid (process ended)."
             $processHasExited = $true
        } catch {
             Write-Warning "Error checking process '$processNameBase' state: $($_.Exception.Message)"
             $processHasExited = $true # Assume exited on error
        }

        if ($processHasExited) {
            $exitCode = -999
            try { $exitCode = $currentProcess.ExitCode } catch { Write-Warning "Could not retrieve ExitCode for process '$processNameBase'." }

            if ($exitCode -eq 0) {
                Write-Host "✅ ($mode worker) Process '$processNameBase' completed successfully." -ForegroundColor Green
            } else {
                Write-Host "❌ ($mode worker) Process '$processNameBase' failed or exited with code $exitCode." -ForegroundColor Red
                # Add reminder about checking FFmpeg output/logs if exit code is non-zero
                if ($exitCode -ne 0) {
                    Write-Host "   Check FFmpeg command output/logs for details (see verbose output for command)." -ForegroundColor DarkRed
                }
            }
            try { $currentProcess.Dispose() } catch {}
            $processVariable.Value = $null # Free up the worker slot
            $script:activeProcessCount--
            Write-Verbose "Decremented active process count to $script:activeProcessCount"
        }
    # *** FIX: Handle case where the variable holds something ELSE (like 'True') ***
    } elseif ($processVariable.Value -ne $null -and -not ($processVariable.Value -is [System.Diagnostics.Process])) {
        # The variable holds something, but it's NOT a process object. This is an error state.
        Write-Error "($mode worker) CRITICAL SCRIPT ERROR: Process variable holds incorrect type '$($processVariable.Value.GetType().Name)' instead of a Process object. Value: '$($processVariable.Value)'. Resetting slot."
        $processVariable.Value = $null # Reset the corrupted slot to prevent repeated errors
        # We might have lost track of a process and the active count could be wrong,
        # but resetting is the safest immediate action.
    } # End check for existing process / object type check

    # --- Part 2: Try to Start New Process ---
    if ($processVariable.Value -eq $null) { # Check if slot is now free (or was already free)
        if ($theQueue.Count -gt 0) {
            $fileToProcess = $theQueue.Dequeue()
            $fileNameOnly = Split-Path $fileToProcess -Leaf
            Write-Host "ℹ️ ($mode worker) Dequeued: $fileNameOnly. Trying to start process. (Queue: $($theQueue.Count))" -ForegroundColor Yellow

            # Ensure Start-FFmpegProcess returns the process object or $null
            $newProcess = Start-FFmpegProcess -inputFile $fileToProcess `
                                              -outputDir $localOutputDirectory `
                                              -mode $mode `
                                              -localFfmpegPath $localFfmpegPath `
                                              -localFfprobePath $localFfprobePath

            # Assign ONLY if $newProcess is actually a process object
            if ($newProcess -ne $null -and $newProcess -is [System.Diagnostics.Process]) {
                 $processVariable.Value = $newProcess
                 # Note: activeProcessCount is incremented inside Start-FFmpegProcess on success
            } elseif ($newProcess -ne $null) {
                 # Start-FFmpegProcess returned something weird, log it
                 Write-Error "($mode worker) Start-FFmpegProcess returned unexpected non-process object: '$newProcess'. Type: $($newProcess.GetType().Name)"
                 # Slot remains null
            } else {
                # Start-FFmpegProcess returned null (error or skipped), message already logged
                Write-Host "⚠️ ($mode worker) Could not start process for '$fileNameOnly' (see errors above). Worker remains free." -ForegroundColor DarkYellow
            }
        }
    } # End check if worker slot is free
}

# --- Main Script ---

# Validate executables
if (-not (Test-FFExecutable -commandPath $ffprobePath) -or -not (Test-FFExecutable -commandPath $ffmpegPath)) {
    exit 1
}

try {
    $script:resolvedFfmpegPath = (Get-Command $ffmpegPath -ErrorAction Stop).Source
    $script:resolvedFfprobePath = (Get-Command $ffprobePath -ErrorAction Stop).Source
    Write-Verbose "Using ffmpeg: $script:resolvedFfmpegPath"
    Write-Verbose "Using ffprobe: $script:resolvedFfprobePath"
} catch {
     Write-Error "Failed to resolve full path for FFmpeg/FFprobe. Ensure they are in PATH or use full paths in config. Error: $($_.Exception.Message)"
     exit 1
}

Write-Host "`n KAIZEN - GPU / CPU Parallel Video Encoder `n" -ForegroundColor Magenta
# ... [Rest of the input loop and main processing loop are unchanged] ...
# ... [Make sure the main loop correctly calls Manage-And-Start-WorkerProcess] ...
# ... [with the correct path variables ($script:resolvedFfmpegPath, etc.)] ...

Write-Host "Output Directory Base: $outputDirectory"
Write-Host "CPU Settings: $cpuPreset / CRF $cpuCrf / $cpuThreads Threads" -ForegroundColor Cyan
Write-Host "GPU Settings: QSV $gpuPreset / Quality $gpuQuality / LookAhead $gpuLookAhead`n" -ForegroundColor DarkCyan

Write-Host "🎥 Enter video file paths (or drag-and-drop). Press Enter on empty line to begin processing:`n" -ForegroundColor Yellow
while ($true) {
    $inputPath = Read-Host "Enter file path"
    if ([string]::IsNullOrWhiteSpace($inputPath)) { break }
    $cleanPath = $inputPath.Trim('"').Trim("'").Trim()
    if (Test-Path $cleanPath -PathType Leaf) {
        $inputQueue.Enqueue($cleanPath)
        Write-Host "  Enqueued: $(Split-Path $cleanPath -Leaf) (Queue size: $($inputQueue.Count))" -ForegroundColor White
    } elseif (Test-Path $cleanPath -PathType Container) {
         Write-Warning "⚠️ Input '$cleanPath' is a directory. Please provide individual file paths."
    } else {
        Write-Warning "⚠️ File not found, not added to queue: $cleanPath"
    }
}

if ($inputQueue.Count -eq 0) {
    Write-Host "`nNo valid files enqueued. Exiting." -ForegroundColor Yellow
    exit
}

Write-Host "`n🔥 Starting processing $($inputQueue.Count) items from queue..." -ForegroundColor Green
Write-Host "   CPU jobs will output to: $(Join-Path $outputDirectory 'CPU')"
Write-Host "   GPU jobs will output to: $(Join-Path $outputDirectory 'GPU')`n"


# --- Keep Awake Logic ---
$previousExecutionState = $null

try {
    if ($script:KeepAwakeAvailable) {
        $keepAwakeFlags = [Kernel32+ExecutionState]::ES_CONTINUOUS -bor [Kernel32+ExecutionState]::ES_SYSTEM_REQUIRED -bor [Kernel32+ExecutionState]::ES_DISPLAY_REQUIRED
        $previousExecutionState = [Kernel32]::SetThreadExecutionState($keepAwakeFlags)

        if ($previousExecutionState -eq [Kernel32+ExecutionState]::ES_NONE) {
            Write-Warning "⚠️ Failed to set thread execution state to keep system awake."
            $previousExecutionState = $null
        } else {
            Write-Host "[Keep Awake] System has been requested to stay active and display left on during processing by this powershell script." -ForegroundColor DarkGray
        }
    }

    # --- Main Processing Loop ---
    Write-Host "Monitoring queue and worker slots... (Press Ctrl+C to attempt graceful stop)"
    while ($inputQueue.Count -gt 0 -or $script:activeProcessCount -gt 0) {
        # Manage CPU process slot...
        Manage-And-Start-WorkerProcess -processVariable ([ref]$cpuProcess) `
                                       -theQueue $inputQueue `
                                       -mode "cpu" `
                                       -localOutputDirectory $outputDirectory `
                                       -localFfmpegPath $script:resolvedFfmpegPath `
                                       -localFfprobePath $script:resolvedFfprobePath

        # Manage GPU process slot...
        Manage-And-Start-WorkerProcess -processVariable ([ref]$gpuProcess) `
                                       -theQueue $inputQueue `
                                       -mode "gpu" `
                                       -localOutputDirectory $outputDirectory `
                                       -localFfmpegPath $script:resolvedFfmpegPath `
                                       -localFfprobePath $script:resolvedFfprobePath

        if ($script:activeProcessCount -gt 0 -or $inputQueue.Count -gt 0) {
            Start-Sleep -Milliseconds 500
        }
    }
    # --- End Main Processing Loop ---

} finally {
    # --- Restore Previous Execution State ---
    if ($script:KeepAwakeAvailable -and $previousExecutionState -ne $null) {
        if ([Kernel32]::SetThreadExecutionState($previousExecutionState) -ne [Kernel32+ExecutionState]::ES_NONE) {
             Write-Host "[Keep Awake] Restored previous system execution state." -ForegroundColor DarkGray
        } else {
             Write-Warning "⚠️ Failed to restore previous system execution state."
             [Kernel32]::SetThreadExecutionState([Kernel32+ExecutionState]::ES_CONTINUOUS) | Out-Null
        }
    } elseif ($script:KeepAwakeAvailable -and $previousExecutionState -eq $null -and $keepAwakeFlags -ne $null) {
         [Kernel32]::SetThreadExecutionState(0) | Out-Null
         Write-Verbose "[Keep Awake] Attempting to clear execution state flags as a fallback."
    }
    # --- End Restore ---
}

Write-Host "`n✨ Queue empty and all tasks completed." -ForegroundColor Green
