# Builds dist\FrameGen-Setup.exe on Windows. From the repo root:
#   powershell -ExecutionPolicy Bypass -File packaging\build.ps1
# Needs 7-Zip (7z.exe) and Inno Setup 6 (iscc.exe) on PATH, and ~10 GB free disk.
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Pinned versions: bump deliberately, then re-run the acceptance checklist.
$MPV_TAG   = "20261021"
$MPV_ASSET = "mpv-x86_64-v3-20261021-git-e471496c56.7z"
$VS_VER    = "R79"  # R80+ dropped API3, which vs-mlrt's vstrt.dll still uses
$MLRT_TAG  = "v15.16"
$UOSC_TAG  = "5.13.0"
$YTDLP_TAG = "2026.08.19"
# Must match portable_config\vs\ladder.json. rife_v2/ is the faster "v2" network used for RIFE 4.26.
$RIFE_MODELS = @("rife/rife_v4.26.onnx", "rife_v2/rife_v4.26.onnx", "rife/rife_v4.6.onnx")

$root  = Split-Path $PSScriptRoot
$build = "$root\build"
$app   = "$build\app"
$dl    = "$build\dl"
$plugins = "$app\vs-runtime\vs-plugins"
if (Test-Path $app) { Remove-Item $app -Recurse -Force }
New-Item -ItemType Directory -Force $app, $dl, $plugins | Out-Null

function Get-File($url) {
    $out = Join-Path $dl (Split-Path $url -Leaf)
    if (-not (Test-Path $out)) {
        Write-Host "Downloading $url"
        Invoke-WebRequest $url -OutFile "$out.part"
        Move-Item "$out.part" $out
    }
    return $out
}
function Expand-7z($archive, $dest, [string[]] $extra = @()) {
    & 7z x $archive "-o$dest" -y @extra | Out-Null
    if ($LASTEXITCODE) { throw "7z failed on $archive" }
}
$gh = "https://github.com"

# mpv
Expand-7z (Get-File "$gh/shinchiro/mpv-winbuild-cmake/releases/download/$MPV_TAG/$MPV_ASSET") $app

# VapourSynth portable (+ embedded Python), via the official installer script
$inst = Get-File "$gh/vapoursynth/vapoursynth/releases/download/$VS_VER/Install-Portable-VapourSynth-$VS_VER.zip"
Expand-Archive $inst "$dl\vsinst" -Force
& "$dl\vsinst\Install-Portable-VapourSynth-$VS_VER.ps1" -TargetFolder "$app\vs-runtime" -Unattended
if (-not (Get-ChildItem "$app\vs-runtime" -Recurse -Filter VSScript.dll)) { throw "VapourSynth install failed" }
# vsmlrt rewrites the RIFE model with the onnx package for scale < 1 (the 4.6 half/quarter levels)
& "$app\vs-runtime\python.exe" -m pip install --no-warn-script-location "onnx==1.23.2"
if ($LASTEXITCODE) { throw "pip install onnx failed" }

# vs-mlrt TensorRT runtime (split archive) + only the RIFE models we use
$mlrt = "$gh/AmusementClub/vs-mlrt/releases/download/$MLRT_TAG"
$part1 = Get-File "$mlrt/vsmlrt-windows-x64-tensorrt.$MLRT_TAG.7z.001"
Get-File "$mlrt/vsmlrt-windows-x64-tensorrt.$MLRT_TAG.7z.002" | Out-Null
Expand-7z $part1 $plugins
# RIFE models ship separately; each archive holds rife/<model>.onnx (v4.6 lives in the older rife_v8 bundle)
$ext = "$gh/AmusementClub/vs-mlrt/releases/download"
$modelArchives = @{
    "rife/rife_v4.26.onnx"    = "$ext/external-models/rife_v4.26.7z"
    "rife_v2/rife_v4.26.onnx" = "$ext/external-models/rife_v4.26.7z"
    "rife/rife_v4.6.onnx"     = "$ext/model-20220923/rife_v8.7z"
}
foreach ($m in $RIFE_MODELS) {
    Expand-7z (Get-File $modelArchives[$m]) "$plugins\models" @(($m -replace "/", "\"))
    if (-not (Test-Path "$plugins\models\$m")) { throw "missing RIFE model $m (archive layout changed?)" }
}
if (-not (Test-Path "$plugins\vstrt.dll")) { throw "vstrt.dll not found (archive layout changed?)" }

# Our config + scripts; vsmlrt.py lives next to fg_vs.py so the import always resolves
Copy-Item "$root\portable_config" "$app\portable_config" -Recurse
$vsmlrtPy = Get-ChildItem $plugins -Recurse -Filter vsmlrt.py | Select-Object -First 1
if (-not $vsmlrtPy) { throw "vsmlrt.py not found" }
Move-Item $vsmlrtPy.FullName "$app\portable_config\vs\vsmlrt.py"

# uosc UI, yt-dlp, launcher
Expand-Archive (Get-File "$gh/tomasklaen/uosc/releases/download/$UOSC_TAG/uosc.zip") "$app\portable_config" -Force
Copy-Item (Get-File "$gh/yt-dlp/yt-dlp/releases/download/$YTDLP_TAG/yt-dlp.exe") "$app\yt-dlp.exe"
Copy-Item "$PSScriptRoot\launch.ps1" "$app\launch.ps1"

# Installer
& iscc "/DAppDir=$app" "/O$root\dist" "$PSScriptRoot\installer.iss"
if ($LASTEXITCODE) { throw "Inno Setup failed" }
Write-Host "Done: $root\dist\FrameGen-Setup.exe" -ForegroundColor Green
