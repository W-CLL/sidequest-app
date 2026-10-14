@echo off
rem 启动支线服务端管理后台（仅本机 127.0.0.1:8788）
cd /d %~dp0
.venv\Scripts\python.exe manage.py runserver 127.0.0.1:8788
