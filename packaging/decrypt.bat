@echo off
setlocal
title rpgm-decrypt
if "%~1"=="" (
  echo.
  echo   rpgm-decrypt — drag a game folder onto this file to decrypt it.
  echo   You get a full, ready-to-run decrypted copy of the game.
  echo   Or run in a terminal:  rpgm-decrypt.exe "C:\path\to\game" "C:\output"
  echo.
  pause
  exit /b 0
)
"%~dp0rpgm-decrypt.exe" "%~1" "%~1-decrypted"
echo.
echo   Done. A full decrypted copy of the game is in:  "%~1-decrypted"
echo.
pause
