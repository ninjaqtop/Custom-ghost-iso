@echo off
REM ============================================================
REM  SetupComplete.cmd - runs as SYSTEM at the end of Windows Setup.
REM  Registers the NoTracking watchdog scheduled tasks and runs the
REM  watchdog once, so enforcement starts before first sign-in.
REM  Log: C:\ProgramData\NoTracking\setupcomplete.log
REM ============================================================

set "NT=C:\ProgramData\NoTracking"
set "ENF=%NT%\enforce.ps1"
set "BAK=%WINDIR%\Setup\NoTracking\enforce.ps1"
set "LOG=%NT%\setupcomplete.log"

if not exist "%NT%" mkdir "%NT%"
echo [%DATE% %TIME%] SetupComplete started >> "%LOG%"

REM --- Ensure the live watchdog copy exists (restore from backup if missing) ---
if not exist "%ENF%" (
  if exist "%BAK%" (
    copy /Y "%BAK%" "%ENF%" >> "%LOG%" 2>&1
    echo [%DATE% %TIME%] enforce.ps1 restored from Windows\Setup backup >> "%LOG%"
  ) else (
    echo [%DATE% %TIME%] ERROR: enforce.ps1 missing in both locations >> "%LOG%"
  )
)

REM --- Same restore for the Sentinel, Guardian, Allow and Remove scripts ---
for %%F in (sentinel.ps1 guardian.ps1 allow.ps1 remove.ps1) do (
  if not exist "%NT%\%%F" (
    if exist "%WINDIR%\Setup\NoTracking\%%F" (
      copy /Y "%WINDIR%\Setup\NoTracking\%%F" "%NT%\%%F" >> "%LOG%" 2>&1
      echo [%DATE% %TIME%] %%F restored from Windows\Setup backup >> "%LOG%"
    ) else (
      echo [%DATE% %TIME%] ERROR: %%F missing in both locations >> "%LOG%"
    )
  )
)

set "ACT=powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\ProgramData\NoTracking\enforce.ps1"

REM --- Watchdog task: at system startup (SYSTEM, before logon) ---
schtasks /Create /TN "NoTracking-Enforce-Startup" /TR "%ACT%" /SC ONSTART /RU SYSTEM /RL HIGHEST /F >> "%LOG%" 2>&1

REM --- Watchdog task: at every user logon ---
schtasks /Create /TN "NoTracking-Enforce-Logon" /TR "%ACT%" /SC ONLOGON /RU SYSTEM /RL HIGHEST /F >> "%LOG%" 2>&1

REM --- Watchdog task: every 5 minutes, forever ---
schtasks /Create /TN "NoTracking-Enforce-30min" /TR "%ACT%" /SC MINUTE /MO 5 /ST 00:05 /RU SYSTEM /RL HIGHEST /F >> "%LOG%" 2>&1

REM --- NOTE: the new-service-install event task (NoTracking-Enforce-Event,
REM     fires on Event 7045) is self-registered by enforce.ps1 on every run ---

REM --- Sentinel task: the always-on real-time layer. schtasks cannot set
REM     an unlimited execution time, so it is registered via PowerShell ---
powershell.exe -NoProfile -Command "try { $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\ProgramData\NoTracking\sentinel.ps1'; $t = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -AtLogOn)); $p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest; $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1); Register-ScheduledTask -TaskName 'NoTracking-Sentinel' -Action $a -Trigger $t -Principal $p -Settings $s -Force | Out-Null } catch {}" >> "%LOG%" 2>&1

REM --- Guardian task: 2-minute supervisor (Sentinel heartbeat, the four
REM     NoTracking tasks, and the three script files) ---
powershell.exe -NoProfile -Command "try { $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\ProgramData\NoTracking\guardian.ps1'; $t = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -AtLogOn), (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 3650))); $p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest; $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5); Register-ScheduledTask -TaskName 'NoTracking-Guardian' -Action $a -Trigger $t -Principal $p -Settings $s -Force | Out-Null } catch {}" >> "%LOG%" 2>&1

REM --- Start the Sentinel now (Enforce also re-verifies it at first logon) ---
schtasks /Run /TN "NoTracking-Sentinel" >> "%LOG%" 2>&1

REM --- Run the watchdog once right now (SYSTEM context) ---
if exist "%ENF%" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ENF%" >> "%LOG%" 2>&1
  echo [%DATE% %TIME%] Initial enforce run finished >> "%LOG%"
)

echo [%DATE% %TIME%] SetupComplete finished >> "%LOG%"
exit /b 0
