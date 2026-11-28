# PowerShell launcher (Windows, or pwsh on macOS / Linux):  .\run   (options: .\run -Help)
# The work is done by tools/run.py, which detects the operating system itself.
$py = $null
foreach ($n in 'py', 'python', 'python3') {
    $c = Get-Command $n -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) {
        & $c.Source -c 'import sys; sys.exit(sys.version_info < (3, 8))' 2>$null
        if ($LASTEXITCODE -eq 0) { $py = $c.Source; break }
    }
}
if (-not $py) {
    Write-Host 'Python 3.8+ not found. Install it from https://www.python.org/downloads/ (or: winget install Python.Python.3.13)' -ForegroundColor Red
    exit 1
}
& $py (Join-Path $PSScriptRoot 'tools/run.py') @args
exit $LASTEXITCODE
