@echo off
setlocal
chcp 65001 >nul
title WindSend Shizuku 守卫 - 开机自启安装
echo 正在将 WindSend Shizuku 守卫注册为开机自启...
set "VBS=%~dp0WindSend-Shizuku-Guard.vbs"
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "WindSendShizukuGuard" /t REG_SZ /d "wscript.exe \"%VBS%\"" /f
echo.
echo 已注册。重启电脑后守卫会自动常驻运行。
echo 如需取消自启，请执行：
echo   reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "WindSendShizukuGuard" /f
echo.
pause
