@echo off
setlocal

REM ============================================================
REM Build VelaShellBridge real-device Lua project (.fprj -> .face)
REM Usage:
REM   build_face.bat [face_file_name] [id]
REM Defaults:
REM   face_file_name = VelaShellBridge.face
REM   id             = 167210067
REM Output:
REM   dist\<face_file_name>
REM ============================================================

set "FACE_NAME=VelaShellBridge.face"
set "FACE_ID=167210067"

if not "%~1"=="" set "FACE_NAME=%~1"
if not "%~2"=="" set "FACE_ID=%~2"

set "ROOT=%~dp0"
set "COMPILER_EXE=%ROOT%Compiler.exe"
set "FPRJ=%ROOT%src\lua\app\VelaShellBridge\VelaShellBridge.fprj"
set "OUTDIR=%ROOT%bin"

for %%I in ("%COMPILER_EXE%") do set "COMPILER_EXE=%%~fI"
for %%I in ("%FPRJ%") do set "FPRJ=%%~fI"
for %%I in ("%OUTDIR%") do set "OUTDIR=%%~fI"

if not exist "%COMPILER_EXE%" (
  echo [ERROR] Compiler.exe not found: "%COMPILER_EXE%"
  exit /b 1
)

if not exist "%FPRJ%" (
  echo [ERROR] Project .fprj not found: "%FPRJ%"
  exit /b 1
)

if not exist "%OUTDIR%" (
  mkdir "%OUTDIR%" >nul 2>&1
)

echo ==========================================
echo Compiler: "%COMPILER_EXE%"
echo Project : "%FPRJ%"
echo Output  : "%OUTDIR%" "%FACE_NAME%" %FACE_ID%
echo ==========================================

"%COMPILER_EXE%" -b "%FPRJ%" "%OUTDIR%" "%FACE_NAME%" %FACE_ID%
if errorlevel 1 (
  echo [ERROR] Build failed.
  exit /b 1
)

echo Done: "%OUTDIR%\%FACE_NAME%"
exit /b 0

