#!/bin/bash
# 将 peggy_id 文本转换为 bytes32 格式（右填充零到 64 个十六进制字符）

PEGGY_ID_TEXT="$1"

if [ -z "$PEGGY_ID_TEXT" ]; then
    echo "用法: $0 <peggy_id_text>" >&2
    exit 1
fi

# 转换为十六进制
PEGGY_ID_HEX=$(echo -n "${PEGGY_ID_TEXT}" | xxd -p | tr -d '\n')

# 右填充零到 64 个字符
PEGGY_ID_PADDED="0x${PEGGY_ID_HEX}$(printf '0%.0s' {1..64} | head -c $((64 - ${#PEGGY_ID_HEX})))"

echo "${PEGGY_ID_PADDED}"

