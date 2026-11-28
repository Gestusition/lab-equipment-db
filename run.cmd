@echo off
rem cmd.exe launcher:  run   (options: run --help)
rem The work is done by tools\run.py, which detects the operating system itself.
setlocal
set "PY="
for %%P in (py python python3) do (
  if not defined PY (
    %%P -c "import sys; sys.exit(sys.version_info < (3, 8))" >nul 2>nul && set "PY=%%P"
  )
)
if not defined PY (
  echo Python 3.8+ not found. Install it from https://www.python.org/downloads/
  exit /b 1
)
%PY% "%~dp0tools\run.py" %*
exit /b %ERRORLEVEL%
