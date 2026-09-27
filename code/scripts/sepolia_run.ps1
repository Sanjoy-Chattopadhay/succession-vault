# Runs scripts/sepolia_run.sh from PowerShell with Git Bash.
#   powershell -ExecutionPolicy Bypass -File scripts\sepolia_run.ps1
#
# Typing `bash` in PowerShell starts WSL's Linux bash, which cannot see the Windows installs of
# forge, cast, node and python. This wrapper starts Git Bash explicitly instead.
$ErrorActionPreference = "Stop"

$candidates = @(
    "$env:ProgramFiles\Git\bin\bash.exe",
    "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
    "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
)
$gitBash = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $gitBash) {
    Write-Error "Git Bash was not found. Install Git for Windows, or open Git Bash and run: bash scripts/sepolia_run.sh"
    exit 1
}

Push-Location (Join-Path $PSScriptRoot "..")
try {
    & $gitBash "scripts/sepolia_run.sh"
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
