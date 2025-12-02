@echo off
REM === 强制 UTF-8，并在结束时恢复原代码页 ===
for /f "tokens=2 delims=: " %%A in ('chcp') do set "_ORIG_CP=%%A"
chcp 65001 >nul
setlocal

REM === 配置 ===
set "DEST_PATH=/data/app/watchface/market/167210065/"
set "STAMP_DIR=.hotreload"

REM 生成 UTC 时间戳文件名（yyyyMMddTHHmmssfffZ）
for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')"`) do set "STAMP_NAME=%%T"
set "STAMP_LOCAL=%TEMP%\%STAMP_NAME%"
type nul > "%STAMP_LOCAL%"

echo ==========================================
echo 删除旧目录：%DEST_PATH%
echo 推送整目录：src/lua  ->  %DEST_PATH%
echo 清空标记目录：%DEST_PATH%%STAMP_DIR%
echo 发布时间戳文件：%STAMP_NAME%
echo ==========================================

REM === 删除目标路径下的整个 167210065 目录 ===
adb shell "rm -rf '%DEST_PATH%'"

REM 推送源代码
adb push "src/lua" "%DEST_PATH%/lua"

REM 推送表盘主文件
adb push "src/resource.bin" "%DEST_PATH%"
adb push "src/watchface_list.json" "/data/app/watchface/"

REM 推送时间戳文件
adb push "%STAMP_LOCAL%" "%DEST_PATH%%STAMP_DIR%/%STAMP_NAME%"

REM 清理本地临时文件
del /f /q "%STAMP_LOCAL%" >nul 2>&1

endlocal
