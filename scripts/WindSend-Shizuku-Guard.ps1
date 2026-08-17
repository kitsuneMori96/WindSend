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

    # usb device present?
    $devices = (& $adb devices 2>$null) -join "`n"
    $attached = $devices -split "`n" | Where-Object { $_ -match '^\S+\s+device$' }
    if (-not $attached) {
        Write-Log 'action: no usb device attached'
        Show-Balloon 'WindSend Shizuku' '未检测到已授权的 USB 设备，请插入数据线并允许调试后重试。'
        exit 1
    }
    Write-Log 'action: usb device attached'

    # shizuku installed?
    $pkg = (& $adb shell pm list packages 2>$null) -join "`n"
    if ($pkg -notmatch 'moe\.shizuku\.xyz') {
        Write-Log 'action: shizuku not installed'
        Show-Balloon 'WindSend Shizuku' '手机未安装 Shizuku，请在手机上安装后重试（shizuku.rikka.app）。'
        exit 1
    }

    # activate if not running
    $pidOut = (& $adb shell pidof moe.shizuku.xyz 2>$null) -join ''
    if ($pidOut -match '\d') {
        Write-Log 'action: shizuku already running'
    } else {
        Write-Log 'action: activating shizuku via adb'
        & $adb shell sh /sdcard/Android/data/moe.shizuku.xyz/start.sh 2>$null | Out-Null
        Start-Sleep -Seconds 3
        $pid2 = (& $adb shell pidof moe.shizuku.xyz 2>$null) -join ''
        if ($pid2 -notmatch '\d') {
            Write-Log 'action: activation failed'
            Show-Balloon 'WindSend Shizuku' 'Shizuku 激活失败，请手动在手机 Shizuku App 内激活。'
            exit 1
        }
    }

    # bring WindSend to foreground so it auto-requests the grant dialog
    Write-Log 'action: bringing WindSend to foreground'
    & $adb shell am start -n com.doraemon.wind_send/.MainActivity 2>$null | Out-Null
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

public class WindSendClipboardGuardForm : Form {
    public const int WM_CLIPBOARDUPDATE = 0x031D;
    public event EventHandler ClipboardUpdated;
    public WindSendClipboardGuardForm() {
        ShowInTaskbar = false;
        FormBorderStyle = FormBorderStyle.None;
        WindowState = FormWindowState.Minimized;
        Opacity = 0;
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_CLIPBOARDUPDATE && ClipboardUpdated != null) {
            ClipboardUpdated(this, EventArgs.Empty);
        }
        base.WndProc(ref m);
    }
}
'@

$script:prevText = $null
$script:lastHandledAt = $null

$form = New-Object WindSendClipboardGuardForm
$hwnd = $form.Handle
if (-not [WindSendClipboardApi]::AddClipboardFormatListener($hwnd)) {
    Write-Log 'guard: AddClipboardFormatListener failed'
    exit 1
}
Write-Log "guard: started (hwnd=$hwnd)"

# Runs synchronously on the UI message-pump thread for every clipboard update.
$form.add_ClipboardUpdated({
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
[System.Windows.Forms.Application]::Run($form)
