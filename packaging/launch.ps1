# Starts Midframe (mpv). If mpv crashes, reopens the same file at the same spot with
# interpolation off (at most twice per session). Startup errors go to launch-error.log + a message box,
# since the shortcut runs this script with a hidden window.
param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Files = @())
$ErrorActionPreference = "Stop"
$app = $PSScriptRoot

trap {
    $_ | Out-String | Set-Content "$app\launch-error.log"
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show("Midframe could not start:`n`n$_`n`nDetails: $app\launch-error.log", "Midframe") | Out-Null
    exit 1
}

if (-not (Test-Path "$app\mpv.exe")) { throw "mpv.exe is missing from $app" }
$vsscript = Get-ChildItem "$app\vs-runtime" -Recurse -Filter VSScript.dll -ErrorAction SilentlyContinue | Select-Object -First 1
if ($vsscript) {
    $env:VSSCRIPT_PATH = $vsscript.FullName
    $env:PATH = "$app\vs-runtime;$($vsscript.DirectoryName);$app;$env:PATH"
}
$state = "$app\portable_config\midframe-last.json"
# Load CUDA kernels on first use: faster TensorRT engine load after every seek (the filter reloads).
$env:CUDA_MODULE_LOADING = "LAZY"

# YouTube changes often: update yt-dlp in the background once a week.
$stamp = "$app\yt-dlp.updated"
if ((Test-Path "$app\yt-dlp.exe") -and (-not (Test-Path $stamp) -or (Get-Item $stamp).LastWriteTime -lt (Get-Date).AddDays(-7))) {
    Start-Process "$app\yt-dlp.exe" "-U" -WindowStyle Hidden
    New-Item $stamp -ItemType File -Force | Out-Null
}

function Quote($a) { '"' + ($a -replace '"', '\"') + '"' }
function Start-Mpv([string[]] $argv) {
    # Start-Process rejects an empty -ArgumentList, so only pass it when there is something to pass.
    if ($argv.Count -gt 0) {
        return Start-Process "$app\mpv.exe" -ArgumentList (($argv | ForEach-Object { Quote $_ }) -join " ") -PassThru -Wait
    }
    return Start-Process "$app\mpv.exe" -PassThru -Wait
}

$argv = $Files
for ($i = 0; $i -le 2; $i++) {
    $p = Start-Mpv $argv
    # 0-4 are mpv's normal exit codes; anything else (e.g. 0xC0000005) is a crash.
    if ($p.ExitCode -ge 0 -and $p.ExitCode -le 4) { break }
    if (-not (Test-Path $state)) { break }
    $last = Get-Content $state -Raw | ConvertFrom-Json
    $argv = @("--start=$($last.pos)", "--script-opts=midframe-enabled=no,midframe-ask=no",
        "--osd-playing-msg=Recovered from a crash - interpolation off (press F to turn it back on)", $last.path)
}
