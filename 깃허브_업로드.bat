@echo off
chcp 65001 >nul
title e-biz실 데이터랩 - GitHub 클라우드 업로드
echo ================================================================
echo  [e-biz실 데이터랩] GitHub Pages 클라우드 동기화를 시작합니다...
echo ================================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0upload_to_github.ps1"
echo.
pause
