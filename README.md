# KAIZEN - GPU / CPU Parallel Video Encoder

Trying to reduce the size of those old family videos, locally? What if you have 100s of videos and 100s of gigabytes to process? What if you don't have those gaming laptops or rigs, and only have modest work laptops with inbuilt graphics?
Meet the Kaizen Video Encoder, created in the powershell language (Though I'm not sure whether powershell should be even considered a language).

This repository contains a set of PowerShell scripts designed to batch-process video files by running two FFmpeg encoding jobs in parallel: one job utilizing the **CPU (software encoding)** and another job utilizing the **GPU (hardware encoding)** to encode your videos from .h264 to hevc format.

This allows you to quickly create a high-quality software encode and a fast hardware encode simultaneously for files in a dynamic queue, maximizing system resource usage.
i.e. one file gets processed using CPU and the other gets processed using GPU; and then when one of them is done, immediately the next item in the queue gets launched to the next hardware lane item.

## Core Features

* **Parallel Processing:** Runs one CPU-bound `libx265` encode and one GPU-bound hardware encode at the same time.
* **Batch Queue:** Allows you to enter or drag-and-drop multiple video files into a queue for processing.
* **Organized Output:** Automatically sorts encoded files into `CPU` and `GPU` subfolders within your specified output directory.
* **Keep Awake:** Uses a Windows P/Invoke call (`SetThreadExecutionState`) to prevent the system from going to sleep during long encoding queues.
* **Smart Conversion:**
    * Encodes video to **H.265 (HEVC)**, tagging it as `hvc1` for broad compatibility (especially with Apple devices, and Windows UWP apps too).
    * Encodes the first audio stream to **AAC** (`-q:a 3`).
    * Copies all subtitle streams (`-c:s copy`).
    * Maps the primary video and audio streams (`-map 0:v:0` and `-map 0:a:0`).
* **Configurable:** Key settings like quality (`CRF`, `gpuQuality`), presets, and file paths are centralized at the top of the script for easy editing.
* **Debugging:** Includes a `$debugKeepWindowOpen = $true` flag, which launches FFmpeg in a new `cmd.exe` window that stays open on completion or error, allowing you to read the output.

## Script Variations

The provided scripts are all functionally identical *except* for the **GPU encoder** they target. You should choose the script that matches your system's hardware.

| Script File | Target GPU Encoder | Hardware |
| :--- | :--- | :--- |
| `pure.ps1` / `last.ps1` | `hevc_qsv` | **Intel** (Quick Sync Video) |
| `pureN.ps1` | `hevc_nvenc` | **NVIDIA** (NVENC) |
| `macos.ps1` | `hevc_toolbox` | **Apple** (VideoToolbox) |

**⚠️ Important Note on `macos.ps1`:** This script is contradictory. While it targets Apple's `hevc_toolbox` encoder, the rest of the script (especially the "Keep Awake" P/Invoke function for `Kernel32.dll`) is **Windows-specific**. This script will **not** run on macOS as-is and will fail on Windows unless you have a custom FFmpeg build. It appears to be an incomplete or experimental version. (Sidenote: I got it to work on Apple laptops but now I dont' have the source code. I'll find it and get back to updating this repo ASAP.)

I haven't created an AMD version as I don't have time for this, sadly! But, if someone can test this for me... well, let's say I'd be ready to do so for you.

## How to Use

1.  **Prerequisites:**
    * A **Windows** operating system (for `pure.ps1`, `last.ps1`, `pureN.ps1`).
    * **FFmpeg** and **FFprobe** installed and accessible from your system's `PATH`. You can test this by typing `ffmpeg -version` in a terminal.

2.  **Choose Your Script:**
    * If you have an **Intel** GPU, use `pure.ps1` or `last.ps1`.
    * If you have an **NVIDIA** GPU, use `pureN.ps1`.

3.  **Configuration (Must):**
    * Open your chosen `.ps1` script in a text editor.
    * At the top, edit the configuration variables to match your preferences:
        * `$outputDirectory`: The base folder where the `CPU` and `GPU` folders will be created.
        * `$cpuPreset`: FFmpeg preset for `libx265` (e.g., `medium`, `slow`).
        * `$cpuCrf`: Quality setting for the CPU encode (lower is better, `24` is a good default).
        * `$gpuPreset`: Preset for the GPU encoder (e.g., `medium`, `slow`).
        * `$gpuQuality`: Quality setting for the GPU encode (e.g., `25`).

4.  **Run the Script:**
    * Open a PowerShell terminal.
    * Navigate to the directory containing the script.
    * Execute the script (e.g., `.\pureN.ps1`).
    * You will be prompted to "Enter file path". You can either paste the full path to a video file or **drag-and-drop the file** onto the terminal window. Press Enter after pasting or dropping the each file.
    * Continue adding all the files you want to encode.
    * When you are finished adding files, press **Enter** on an empty line.

The script will start processing the queue, launching one CPU and one GPU encode. As soon as a slot becomes free, it will automatically pick up the next item from the queue until all files are processed. The script will also check for duplicates during processing.

## Warning

Your laptop / desktop rig will definetely become insanely hot and this will be battery intensive while trying to use this script and processing multiple files. Use a good cooler and please supply your laptop with good power.

## But why PowerShell, why not bash or Python?

This is built to be insanely fast, and while processing such videos, every inch of resource power counts. Powershell is also pretty much better in terms of writing raw code as such.

## Pro Tips

1. Keep the videos on the system drive or on a NVMe SSD, as we need high reading speeds during processing.
2. The script was built with my knowledge of computers and the help of multiple AIs. However, the entire logic is mine. Thus, there are some human optimizations behind those walls of code, and it's insanely human-readable to an extent. Raise an issue in this repo if you find anything weird with the script.

## Can I change the code and contribute to the repo?

You're absolutely welcome to do so. If you want to, we can work to convert this into a GUI based app itself. Just fork this repo and suggest your changes, or better yet, reach out to me via [https://sugeeth.craft.me](https://sugeeth.craft.me)
