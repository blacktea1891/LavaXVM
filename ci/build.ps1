$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force build,dist,dist/LavaXVM | Out-Null
Start-Transcript -Path dist/build.log
try {
  $vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
  $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
  if (!$vs) { throw 'MSVC C++ tools missing' }
  $dev = Join-Path $vs 'Common7/Tools/VsDevCmd.bat'
  # Import the official MSVC x86 developer environment.
  cmd /d /s /c "`"$dev`" -no_logo -arch=x86 -host_arch=x64 && set" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($matches[1],$matches[2],'Process') }
  }
  # The old resource script includes MFC's afxres.h but only needs Win32 definitions.
  "#include <windows.h>`n#ifndef IDC_STATIC`n#define IDC_STATIC (-1)`n#endif" | Set-Content build/afxres.h -Encoding ascii
  & rc.exe /nologo /c936 /i build /fo build/LVM.res Script1.rc
  if ($LASTEXITCODE) { throw 'Resource compilation failed' }
  # Match LVM.vcproj Release: C, ANSI/GBK, /O2 /Ob1 /GF /Gy /MT, Windows subsystem, winmm.
  $sources = @('cheat.c','check.c','filelist.c','lava.c','main.c','message.c','py2gb.c','screen.c')
  & cl.exe /nologo /TC /O2 /Ob1 /GF /Gy /MT /W3 /DWIN32 /DNDEBUG /D_WINDOWS /D_CRT_SECURE_NO_WARNINGS /source-charset:.936 /execution-charset:.936 /Fobuild/ /Fedist/LavaXVM/LVM.exe $sources /link build/LVM.res /SUBSYSTEM:WINDOWS /MACHINE:X86 /INCREMENTAL:NO user32.lib gdi32.lib comdlg32.lib advapi32.lib winmm.lib
  if ($LASTEXITCODE) { throw 'C compilation/link failed' }
  & dumpbin.exe /headers dist/LavaXVM/LVM.exe | Out-File dist/pe-headers.txt
  & dumpbin.exe /dependents dist/LavaXVM/LVM.exe | Tee-Object -FilePath dist/dependencies.txt
  Copy-Item LICENSE dist/LavaXVM/LICENSE.txt
  Copy-Item ci/RUNNING.txt dist/LavaXVM/README.txt
  git rev-parse HEAD | Set-Content dist/source-commit.txt
  $bin = (Resolve-Path dist/LavaXVM).Path
  Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class LvmWindow {
  public delegate bool EnumProc(IntPtr hwnd, IntPtr param);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr param);
  [DllImport("user32.dll", CharSet=CharSet.Ansi)] public static extern int GetClassName(IntPtr hwnd, System.Text.StringBuilder text, int count);
  [DllImport("user32.dll", CharSet=CharSet.Ansi)] public static extern IntPtr FindWindow(string cls, string title);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr wp, IntPtr lp);
}
'@
  $p = Start-Process -FilePath "$bin/LVM.exe" -WorkingDirectory $bin -WindowStyle Hidden -PassThru
  try {
    $ready = $false
    for ($i=0; $i -lt 20; $i++) {
      Start-Sleep -Milliseconds 500
      $p.Refresh()
      if ($p.HasExited) { throw "Startup failed: exit $($p.ExitCode)" }
      $hwnd = [LvmWindow]::FindWindow('MyLvmClass', $null)
      [uint32]$owner = 0
      if ($hwnd -ne [IntPtr]::Zero) { [void][LvmWindow]::GetWindowThreadProcessId($hwnd,[ref]$owner) }
      if ($owner -eq $p.Id) { $ready = $true; break }
    }
    if (!$ready) {
      $script:foundWindow = [IntPtr]::Zero
      [LvmWindow]::EnumWindows({ param($w,$unused)
        [uint32]$wpid=0
        [void][LvmWindow]::GetWindowThreadProcessId($w,[ref]$wpid)
        if ($wpid -eq $p.Id) {
          $name = [System.Text.StringBuilder]::new(256)
          [void][LvmWindow]::GetClassName($w,$name,256)
          Write-Host "Process window: $w class=$name"
          if ($name.ToString() -eq 'MyLvmClass') { $script:foundWindow=$w }
        }
        return $true
      },[IntPtr]::Zero) | Out-Null
      $hwnd=$script:foundWindow
      if ($hwnd -eq [IntPtr]::Zero) { throw 'No main window within 10 seconds' }
    }
    "PASS: GUI class MyLvmClass created; process alive; PID=$($p.Id)" | Tee-Object -FilePath dist/startup-check.txt
    if (![LvmWindow]::PostMessage($hwnd,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)) { throw 'WM_CLOSE failed' }
    if (!$p.WaitForExit(5000)) { throw 'GUI did not exit after close' }
    if ($p.ExitCode -ne 0) { throw "Exit code $($p.ExitCode)" }
    'PASS: window closed cleanly, exit 0' | Add-Content dist/startup-check.txt
  } finally { if (!$p.HasExited) { $p.Kill() } }
  # Exclude test-generated CPU calibration/configuration from the distributable.
  Remove-Item "$bin/lavax.ini" -ErrorAction SilentlyContinue
  Copy-Item dist/LavaXVM/LVM.exe dist/LVM.exe
  Compress-Archive -Path dist/LavaXVM -DestinationPath dist/LavaXVM-Release-x86.zip -Force
  Get-FileHash dist/LVM.exe,dist/LavaXVM-Release-x86.zip -Algorithm SHA256 | Format-Table -AutoSize | Out-File dist/SHA256.txt
} finally { Stop-Transcript }

