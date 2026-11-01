@echo off
chcp 936 >nul
title FPGA UART Console Server
cd /d "D:\pango\img_correct\img_correct_backup_vga\host"
echo.
echo   Starting local server for FPGA UART console...
echo   Browser will open automatically.
echo   Keep this window open while using the console.
echo.
start "" "msedge.exe" "http://localhost:8765/control.html"
"C:\Users\16970\AppData\Local\Programs\Python\Python311\python.exe" -m http.server 8765
pause
