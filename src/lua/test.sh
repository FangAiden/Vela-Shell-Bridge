#!/bin/sh
echo "=== Error Code Test ==="

# 1. 创建一个必定失败的子脚本（调用一个不存在的命令，标准sh应该返回127）
echo "this_cmd_does_not_exist" > fail.sh

# 2. 使用 if 执行它，并在 else 中查看 $?
if sh fail.sh > /dev/null
then
    echo "Unexpected: Command succeeded"
else
    ERR=$?
    echo "Captured Error Code: $ERR"
fi

# 清理
rm fail.sh