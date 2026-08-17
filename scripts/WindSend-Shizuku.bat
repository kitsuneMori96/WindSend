@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul
title WindSend - Shizuku 一键启用
echo ============================================
echo   WindSend Shizuku 一键启用（无需 root）
echo   前置：手机已开启 USB 调试并连接本电脑
echo ============================================
echo.

REM ---- locate adb ----
set "ADB="
where adb >nul 2>nul
if %errorlevel% equ 0 (
  set "ADB=adb"
) else (
  for %%p in (
    "%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe"
    "C:\Android\platform-tools\adb.exe"
    "D:\Android\platform-tools\adb.exe"
    "%USERPROFILE%\AppData\Local\Android\Sdk\platform-tools\adb.exe"
  ) do (
    if exist "%%~p" set "ADB=%%~p"
  )
)
if not defined ADB (
  echo [错误] 未找到 adb。
  echo 请安装 Android platform-tools：
  echo   https://developer.android.com/tools/releases/platform-tools
  echo 或使用手机上的"无线调试"方式在 Shizuku App 内自行激活。
  pause
  exit /b 1
)
echo [adb] !ADB!
echo.

REM ---- check device ----
"!ADB!" get-state >nul 2>nul
if errorlevel 1 (
  echo [错误] 未检测到已授权的手机，请：
  echo   1. 用数据线连接手机
  echo   2. 开启开发者选项中的"USB 调试"并允许本电脑
  echo   3. 手机上如有授权弹窗请点"允许"
  pause
  exit /b 1
)
echo [设备] 已连接：
"!ADB!" devices | findstr /v "List of"
echo.

REM ---- check Shizuku installed ----
"!ADB!" shell pm list packages 2>nul | findstr /i "moe.shizuku.xyz" >nul
if errorlevel 1 (
  echo [提示] 手机未安装 Shizuku，正在打开下载页面...
  echo 请安装后重新运行本脚本。
  start https://shizuku.rikka.app
  pause
  exit /b 1
)
echo [检测] Shizuku 已安装。
echo.

REM ---- check if already activated ----
"!ADB!" shell pidof moe.shizuku.xyz >nul 2>nul
if not errorlevel 1 (
  echo [检测] Shizuku 已在运行，跳过激活。
) else (
  echo [激活] 正在通过 adb 启动 Shizuku 服务...
  "!ADB!" shell sh /sdcard/Android/data/moe.shizuku.xyz/start.sh
  if errorlevel 1 (
    echo [重试] 使用兼容路径再次尝试...
    "!ADB!" shell sh /sdcard/Android/data/moe.shizuku.xyz/api/start.sh
  )
  timeout /t 2 >nul
  "!ADB!" shell pidof moe.shizuku.xyz >nul 2>nul
  if errorlevel 1 (
    echo [警告] 未能确认 Shizuku 服务进程。
    echo 若手机已开启无线调试，也可在 Shizuku App 内选择"无线调试"方式激活。
  ) else (
    echo [完成] Shizuku 服务已启动。
  )
)
echo.

echo [授权] 正在打开 WindSend 并请求 Shizuku 授权...
"!ADB!" shell am start -n com.doraemon.wind_send/.MainActivity
echo.
echo ============================================
echo   请在手机上：在弹出的 Shizuku 授权对话框中
echo   点击"允许"（仅需一次）。
echo   授权后 WindSend 将自动获得后台剪贴板监听。
echo ============================================
echo.
pause