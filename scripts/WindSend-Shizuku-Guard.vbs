' WindSend Shizuku 守卫 - 无窗口常驻启动器
' 用法：双击本文件即可启动（或通过自启脚本开机运行）

Set ws = CreateObject("Wscript.Shell")
scriptDir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
ws.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptDir & "WindSend-Shizuku-Guard.ps1""", 0, False
