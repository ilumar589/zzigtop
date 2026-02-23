param(
    [ValidateSet("Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall")]
    [string]$Optimize = "Debug",

    [switch]$BuildOnly,

    [switch]$Clean,

    [switch]$Server,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExeArgs
)

$ErrorActionPreference = "Stop"
$ProjectRoot = $PSScriptRoot

if ($Server) {
    $ExePath = Join-Path $ProjectRoot "zig-out\bin\http_server.exe"
} else {
    $ExePath = Join-Path $ProjectRoot "zig-out\bin\zzigtop.exe"
}

# Clean build artifacts
if ($Clean) {
    Write-Host "Cleaning build artifacts..." -ForegroundColor Yellow
    $zigCache = Join-Path $ProjectRoot ".zig-cache"
    $zigOut = Join-Path $ProjectRoot "zig-out"
    if (Test-Path $zigCache) { Remove-Item -Recurse -Force $zigCache }
    if (Test-Path $zigOut) { Remove-Item -Recurse -Force $zigOut }
    Write-Host "Clean complete." -ForegroundColor Green
}

# Build
Write-Host "Building with -Doptimize=$Optimize ..." -ForegroundColor Cyan
$buildArgs = @("build", "-Doptimize=$Optimize")
& zig @buildArgs

if ($LASTEXITCODE -ne 0) {
    Write-Host "Build failed with exit code $LASTEXITCODE" -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Host "Build succeeded. Output: $ExePath" -ForegroundColor Green

if ($BuildOnly) {
    exit 0
}

# Run
if ($Server) {
    Write-Host "`nStarting HTTP server ..." -ForegroundColor Cyan
    Write-Host "Press Ctrl+C to stop.`n" -ForegroundColor Yellow
}
else {
    Write-Host "`nRunning $ExePath ..." -ForegroundColor Cyan
}
& $ExePath @ExeArgs
exit $LASTEXITCODE
