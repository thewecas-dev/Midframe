# Starts FrameGen (mpv). If mpv crashes, reopens the same file at the same spot with
# interpolation off (at most twice per session).
param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Files = @())

$app = $PSScriptRoot
$vsscript = Get-ChildItem "$app\vs-runtime" -Recurse -Filter VSScript.dll | Select-Object -First 1
$env:VSSCRIPT_PATH = $vsscript.FullName
$env:PATH = "$app\vs-runtime;$($vsscript.DirectoryName);$app;$env:PATH"
$state = "$app\portable_config\framegen-last.json"

# YouTube changes often: update yt-dlp in the background once a week.
$stamp = "$app\yt-dlp.updated"
if (-not (Test-Path $stamp) -or (Get-Item $stamp).LastWriteTime -lt (Get-Date).AddDays(-7)) {
    Start-Process "$app\yt-dlp.exe" "-U" -WindowStyle Hidden
    New-Item $stamp -ItemType File -Force | Out-Null
}

function Quote($a) { '"' + ($a -replace '"', '\"') + '"' }

$argv = $Files
for ($i = 0; $i -le 2; $i++) {
    $p = Start-Process "$app\mpv.exe" -ArgumentList (($argv | ForEach-Object { Quote $_ }) -join " ") -PassThru -Wait
    # 0-4 are mpv's normal exit codes; anything else (e.g. 0xC0000005) is a crash.
    if ($p.ExitCode -ge 0 -and $p.ExitCode -le 4) { break }
    if (-not (Test-Path $state)) { break }
    $last = Get-Content $state -Raw | ConvertFrom-Json
    $argv = @("--start=$($last.pos)", "--script-opts=framegen-enabled=no",
        "--osd-playing-msg=Recovered from a crash - interpolation off (press F to turn it back on)", $last.path)
}
