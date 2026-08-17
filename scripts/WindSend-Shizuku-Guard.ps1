#requires -version 5.1
#
# WindSend-Shizuku-Guard.ps1
#
# 常驻剪贴板守卫（事件驱动，零轮询）：
# 手机端检测到 Shizuku 缺失/未激活/未授权时，会通过同步会话发来控制令牌
# (windsend://shizuku?action=activate)，令牌落到电脑剪贴板。
# 本守卫通过 Win32 AddClipboardFormatListener 即时感知剪贴板变化，
# 匹配令牌后：立即还原剪贴板 -> 调用 adb 激活 Shizuku -> 拉起手机上的 WindSend
# 弹出授权对话框。全程无需用户手动操作。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "WindSend-Shizuku-Guard.ps1"
#   （常驻运行；可用 WindSend-Shizuku-Guard.vbs 无窗口启动）

param([switch]$Action)

$ErrorActionPreference = 'SilentlyContinue'
$scriptPath = $MyInvocation.MyCommand.Path

function Write-Log([string]$msg) {
    $LogPath = Join-Path $env:TEMP 'windsend-shizuku-guard.log'
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    try { Add-Content -Path $LogPath -Value $line -Encoding UTF8 } catch { }
}

function Show-Balloon([string]$title, [string]$text) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.Icon = [System.Drawing.SystemIcons]::Information
        $notify.BalloonTipTitle = $title
        $notify.BalloonTipText = $text
        $notify.Visible = $true
        $notify.ShowBalloonTip(10000)
        Start-Sleep -Seconds 11
        $notify.Dispose()
    } catch { }
}

# ---------------------------------------------------------------- action mode
if ($Action) {
    Write-Log 'action: handling shizuku control token'

    # adb invocation with a hard timeout. The adb server can stall on a
    # half-dead transport (e.g. the wireless mDNS one), so never rely on adb
    # returning on its own.
    function Invoke-Adb([string[]]$argsList, [int]$timeoutSec = 25) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $adb
        $psi.Arguments = (
            $argsList | ForEach-Object {
                if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
            }
        ) -join ' '
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        try {
            $p = [System.Diagnostics.Process]::Start($psi)
        } catch {
            Write-Log "action: adb launch failed: $_"
            return $null
        }
        # Read the pipes asynchronously BEFORE waiting: large outputs (e.g.
        # pm list packages) would otherwise fill the pipe buffer and deadlock
        # the child, which then never exits.
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($timeoutSec * 1000)) {
            Write-Log "action: adb timed out: $($argsList -join ' ')"
            try { $p.Kill() } catch { }
            return $null
        }
        return $outTask.Result
    }

    # locate adb
    $adb = $null
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { $adb = $cmd.Source }
    if (-not $adb) {
        foreach ($c in @(
            "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
            "$env:USERPROFILE\AppData\Local\Android\Sdk\platform-tools\adb.exe",
            'C:\Android\platform-tools\adb.exe',
            'D:\Android\platform-tools\adb.exe',
            'D:\soft\android-sdk\platform-tools\adb.exe'
        )) {
            if (Test-Path $c) { $adb = $c; break }
        }
    }
    if (-not $adb) {
        Write-Log 'action: adb not found'
        Show-Balloon 'WindSend Shizuku' '未找到 adb，请安装 Android platform-tools。'
        exit 1
    }

    # usb device present? (the wireless mDNS transport flaps and can stall
    # the adb server, so retry and drop wireless transports for stability)
    $serials = @()
    for ($i = 0; $i -lt 3; $i++) {
        $devices = Invoke-Adb @('devices')
        if ($devices) {
            $serials = $devices -split '\r?\n' |
                Where-Object { $_ -match '^\S+\s+device$' } |
                ForEach-Object { ($_ -split '\s+')[0] }
            if ($serials) { break }
        }
        Write-Log "action: adb devices retry $($i + 1)"
        Start-Sleep -Seconds 2
    }
    foreach ($s in $serials) {
        if ($s -match '^adb-') {
            Invoke-Adb @('disconnect', $s) | Out-Null
        }
    }
    # Prefer a USB transport; the phone may also expose a wireless mDNS
    # transport (adb-...), and adb refuses to run without -s when both exist.
    $serial = $serials | Where-Object { $_ -notmatch '^adb-' } |
        Select-Object -First 1
    if (-not $serial) { $serial = $serials | Select-Object -First 1 }
    if (-not $serial) {
        Write-Log 'action: no usb device attached'
        Show-Balloon 'WindSend Shizuku' '未检测到已授权的 USB 设备，请插入数据线并允许调试后重试。'
        exit 1
    }
    Write-Log "action: usb device attached (serial=$serial)"
    $adbTarget = @('-s', $serial)

    # shizuku installed?
    $pkg = Invoke-Adb @('shell', 'pm', 'list', 'packages') -timeoutSec 40
    Write-Log "action: pm list done ($($pkg -ne $null))"
    if (-not $pkg -or $pkg -notmatch 'moe\.shizuku') {
        Write-Log 'action: shizuku not installed'
        Show-Balloon 'WindSend Shizuku' '手机未安装 Shizuku，请在手机上安装后重试（shizuku.rikka.app）。'
        exit 1
    }

    # activate if not running
    $pidOut = Invoke-Adb @('shell', 'pidof', 'shizuku_server')
    if ($pidOut -match '\d') {
        Write-Log 'action: shizuku already running'
    } else {
        Write-Log 'action: activating shizuku via adb'
        # Modern Shizuku v13+: run the starter directly from the APK's native
        # lib directory (start.sh is only written after the app is opened).
        $apk = (Invoke-Adb @('shell', 'pm', 'path', 'moe.shizuku.privileged.api')) -replace '^package:', ''
        $apk = $apk.Trim()
        $abi = (Invoke-Adb @('shell', 'getprop', 'ro.product.cpu.abi')).Trim()
        if ($abi -match '^(\w+?)-') { $abi = $matches[1] }
        $candidates = @()
        if ($apk -and $abi) {
            $libDir = ($apk -replace '/base\.apk$', '') + '/lib'
            $candidates += "$libDir/$abi/libshizuku.so"
            $candidates += "$libDir/arm64/libshizuku.so"
        }
        $candidates += '/sdcard/Android/data/moe.shizuku.privileged.api/start.sh'
        $candidates += '/sdcard/Android/data/moe.shizuku.privileged.api/files/start.sh'
        $activated = $false
        foreach ($c in $candidates) {
            $exists = Invoke-Adb @('shell', "ls $c")
            if (-not $exists) { continue }
            Write-Log "action: trying $c"
            if ($c.EndsWith('.sh')) {
                Invoke-Adb @('shell', "sh $c") | Out-Null
            } else {
                Invoke-Adb @('shell', $c) | Out-Null
            }
            Start-Sleep -Seconds 3
            $pid2 = Invoke-Adb @('shell', 'pidof', 'shizuku_server')
            if ($pid2 -match '\d') { $activated = $true; break }
        }
        if (-not $activated) {
            Write-Log 'action: activation failed'
            Show-Balloon 'WindSend Shizuku' 'Shizuku 激活失败，请手动在手机 Shizuku App 内激活。'
            exit 1
        }
    }

    # bring WindSend to foreground so it auto-requests the grant dialog,
    # but never if it is already focused - an `am start` would land on top
    # of the Shizuku grant dialog and dismiss it.
    $focus = (Invoke-Adb @('shell', 'dumpsys', 'window') -join ' ')
    if ($focus -match 'mCurrentFocus=.*com\.doraemon\.wind_send') {
        Write-Log 'action: WindSend already focused, skipping am start'
    } else {
        Write-Log 'action: bringing WindSend to foreground'
        Invoke-Adb @('shell', 'am', 'start', '-n', 'com.doraemon.wind_send/.MainActivity') | Out-Null
    }
    Write-Log 'action: done - please tap Allow on the phone'
    exit 0
}

# ---------------------------------------------------------------- guard mode
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class WindSendClipboardApi {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool AddClipboardFormatListener(IntPtr hwnd);
}

public class WindSendClipboardGuardWindow : NativeWindow {
    public const int WM_CLIPBOARDUPDATE = 0x031D;
    public event EventHandler ClipboardUpdated;
    public IntPtr CreateListenerWindow() {
        CreateHandle(new CreateParams());
        return Handle;
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_CLIPBOARDUPDATE && ClipboardUpdated != null) {
            ClipboardUpdated(this, EventArgs.Empty);
        }
        base.WndProc(ref m);
    }
}
'@ -ReferencedAssemblies System.Windows.Forms, System.Drawing

$script:prevText = $null
$script:lastHandledAt = $null

$window = New-Object WindSendClipboardGuardWindow
$hwnd = $window.CreateListenerWindow()
if (-not [WindSendClipboardApi]::AddClipboardFormatListener($hwnd)) {
    Write-Log "guard: AddClipboardFormatListener failed (hwnd=$hwnd)"
    exit 1
}
Write-Log "guard: started (hwnd=$hwnd)"

# Runs synchronously on the UI message-pump thread for every clipboard update.
$window.add_ClipboardUpdated({
    $text = $null
    try {
        $text = [System.Windows.Forms.Clipboard]::GetText(
            [System.Windows.Forms.TextDataFormat]::Text)
    } catch { }
    if ($text -and $text.StartsWith('windsend://shizuku?')) {
        $now = Get-Date
        $cooled = $null -eq $script:lastHandledAt -or
            $now.Subtract($script:lastHandledAt).TotalSeconds -gt 30
        if (-not $cooled) {
            Write-Log 'guard: control token ignored (cooldown)'
            return
        }
        $script:lastHandledAt = $now
        Write-Log "guard: control token received: $text"
        try {
            if ($script:prevText -and $script:prevText.Length -gt 0) {
                [System.Windows.Forms.Clipboard]::SetText($script:prevText)
            } else {
                [System.Windows.Forms.Clipboard]::Clear()
            }
        } catch { }
        Start-Process powershell -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', ('"{0}"' -f $scriptPath), '-Action'
        )
        return
    }
    $script:prevText = $text
})

Write-Log 'guard: listening for clipboard updates'
[System.Windows.Forms.Application]::Run()
