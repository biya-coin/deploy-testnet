#!/bin/bash
# 查看节点日志脚本（支持节点和 Peggo 日志）

set -e

# 进入 ansible 目录（脚本在 ansible/bin/ 下）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ANSIBLE_DIR"

# 解析参数
HOST_NAME=""
FOLLOW=false
LINES=50
SERVICE_TYPE="node"  # 默认查询节点日志，使用 --peggo 时改为 peggo
NEED_PASSWORD=""  # 自动检测

show_usage() {
    echo "用法: $0 --host HOST [选项]"
    echo ""
    echo "选项:"
    echo "  --host HOST              查看指定主机日志（必需，如: validator-0, sentry-0）"
    echo "  --peggo                  查询 Peggo 日志（默认查询节点日志）"
    echo "  --follow, -f              实时跟踪日志（类似 tail -f）"
    echo "  --lines N, -n N           显示最近 N 行日志（默认: 50）"
    echo "  --help, -h                显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0 --host validator-0             查看 validator-0 的节点日志"
    echo "  $0 --host validator-0 --peggo     查看 validator-0 的 Peggo 日志"
    echo "  $0 --host validator-0 -f          实时查看 validator-0 的节点日志"
    echo "  $0 --host validator-0 --peggo -f  实时查看 validator-0 的 Peggo 日志"
    echo "  $0 --host sentry-0 -n 100          查看 sentry-0 最近100行节点日志"
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --host)
            HOST_NAME="$2"
            shift 2
            ;;
        --peggo)
            SERVICE_TYPE="peggo"
            shift
            ;;
        --follow|-f)
            FOLLOW=true
            shift
            ;;
        --lines|-n)
            LINES="$2"
            shift 2
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            show_usage
            exit 1
            ;;
    esac
done

# 如果没有指定主机，显示帮助
if [ -z "$HOST_NAME" ]; then
    echo "错误: 必须指定 --host 参数"
    echo ""
    show_usage
    exit 1
fi

# 确定要查询的主机
LIMIT_HOST="$HOST_NAME"
HOST_DESC="$HOST_NAME"

# 确定服务名称模式
if [ "$SERVICE_TYPE" == "peggo" ]; then
    SERVICE_PATTERN="peggo"
    SERVICE_DESC="Peggo 日志"
else
    SERVICE_PATTERN="biyachaind"
    SERVICE_DESC="节点日志"
fi

# 检测是否需要密码认证
if [ -z "$NEED_PASSWORD" ]; then
    # 尝试无密码连接目标主机
    ansible $LIMIT_HOST -i inventory.yml -m ping -o &>/dev/null
    if [ $? -eq 0 ]; then
        NEED_PASSWORD=false
    else
        NEED_PASSWORD=true
    fi
fi

# 获取主机信息用于显示
echo "=========================================="
echo "查看 $SERVICE_DESC"
echo "=========================================="
echo "目标: $HOST_DESC"
echo "服务: $SERVICE_PATTERN"
if [ "$FOLLOW" == true ]; then
    echo "模式: 实时跟踪（按 Ctrl+C 退出）"
else
    echo "模式: 显示最近 $LINES 行"
fi
echo "=========================================="
echo ""

# 构建 ansible 命令
if [ "$FOLLOW" == true ]; then
    # 实时跟踪模式：直接跟踪最新日志
    echo "正在连接服务器并开始实时跟踪日志..."
    echo ""
    
    # 获取服务器IP和用户名
    SERVER_INFO=$(ansible-inventory -i inventory.yml --host "$LIMIT_HOST" 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    ansible_host = data.get('ansible_host', '')
    ansible_user = data.get('ansible_user', 'ubuntu')
    print(f'{ansible_host}|{ansible_user}')
except:
    print('')
" 2>/dev/null)
    
    if [ -n "$SERVER_INFO" ] && [ "$SERVER_INFO" != "|" ]; then
        SERVER_IP=$(echo "$SERVER_INFO" | cut -d'|' -f1)
        SERVER_USER=$(echo "$SERVER_INFO" | cut -d'|' -f2)
        
        if [ -n "$SERVER_IP" ] && [ -n "$SERVER_USER" ]; then
            # 直接使用 SSH 连接，避免 Ansible 的输出缓冲问题
            echo "连接到: $SERVER_USER@$SERVER_IP"
            if [ "$NEED_PASSWORD" == true ]; then
                echo "提示: 请输入 SSH 密码"
            fi
            echo ""
            ssh -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                "$SERVER_USER@$SERVER_IP" \
                "sudo journalctl -u $SERVICE_PATTERN -f --no-pager"
            exit $?
        fi
    fi
    
    # 备用方法：使用 ansible raw 模块
    if [ "$NEED_PASSWORD" == true ]; then
        ansible $LIMIT_HOST -i inventory.yml -m raw \
            -a "sudo journalctl -u $SERVICE_PATTERN -f --no-pager" \
            --ask-pass --ask-become-pass
    else
        ansible $LIMIT_HOST -i inventory.yml -m raw \
            -a "sudo journalctl -u $SERVICE_PATTERN -f --no-pager" \
            --become
    fi
else
    # 显示最近N行日志
    if [ "$NEED_PASSWORD" == true ]; then
        ansible $LIMIT_HOST -i inventory.yml -m shell \
            -a "sudo journalctl -u $SERVICE_PATTERN -n $LINES --no-pager" \
            --ask-pass --ask-become-pass
    else
        ansible $LIMIT_HOST -i inventory.yml -m shell \
            -a "sudo journalctl -u $SERVICE_PATTERN -n $LINES --no-pager" \
            --become
    fi
fi
