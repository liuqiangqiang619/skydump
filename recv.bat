@echo off
chcp 65001 >nul
set PYTHONIOENCODING=utf-8
set PY="C:\Users\65651\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
if not exist "%PY%" set PY=python
"%PY%" "%~dp0recv.py" %*
pause