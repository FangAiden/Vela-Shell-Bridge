param(
  [string]$Serial = "emulator-5554",
  [string]$RemoteDir = "/tmp/vela_shell_probe"
)

$ErrorActionPreference = "Stop"

function Invoke-AdbShell([string]$Cmd) {
  & adb -s $Serial shell $Cmd
}

Write-Host "== Device ==" -ForegroundColor Cyan
& adb -s $Serial get-state | Out-Host
Invoke-AdbShell "uname -a" | Out-Host
Write-Host ""

Write-Host "== Commands (help) ==" -ForegroundColor Cyan
Invoke-AdbShell "help" | Out-Host
Write-Host ""

Write-Host "== Feature probes ==" -ForegroundColor Cyan
Invoke-AdbShell "mkdir -p $RemoteDir" | Out-Host

$localTmp = Join-Path $env:TEMP ("vela_shell_probe_" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $localTmp | Out-Null

try {
  $probe1 = Join-Path $localTmp "probe_bg_pid.sh"
  @'
echo "== bg + $! stability =="
sleep 2 &
echo $! > /tmp/vela_pid
echo "PID_IMMEDIATE=$!"
echo foo
echo "PID_AFTER=$!"
echo "PID_FILE=`cat /tmp/vela_pid`"
wait `cat /tmp/vela_pid`
echo "WAIT_DONE"
rm /tmp/vela_pid
'@ | Set-Content -Path $probe1 -Encoding ASCII

  & adb -s $Serial push $probe1 "$RemoteDir/probe_bg_pid.sh" | Out-Host
  Invoke-AdbShell "sh $RemoteDir/probe_bg_pid.sh" | Out-Host
  Write-Host ""

  $probe2 = Join-Path $localTmp "probe_if_semicolon.sh"
  @'
echo "== if + semicolon in condition (known-bad) =="
if sleep 1; echo done > /tmp/vela_if_out
then
  echo 0 > /tmp/vela_if_status
else
  echo 1 > /tmp/vela_if_status
fi
'@ | Set-Content -Path $probe2 -Encoding ASCII

  & adb -s $Serial push $probe2 "$RemoteDir/probe_if_semicolon.sh" | Out-Host
  Invoke-AdbShell "sh $RemoteDir/probe_if_semicolon.sh" | Out-Host
  Write-Host ""

  $probe3 = Join-Path $localTmp "probe_backtick.sh"
  @'
echo "== backticks =="
echo "X=`echo hi`"
'@ | Set-Content -Path $probe3 -Encoding ASCII

  & adb -s $Serial push $probe3 "$RemoteDir/probe_backtick.sh" | Out-Host
  Invoke-AdbShell "sh $RemoteDir/probe_backtick.sh" | Out-Host
  Write-Host ""
}
finally {
  try { Invoke-AdbShell "rm -rf $RemoteDir" | Out-Host } catch {}
  try { Remove-Item -Recurse -Force $localTmp } catch {}
}
