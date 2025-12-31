#!/bin/bash

# 节点控制脚本
# 功能：启动、停止、重启节点和 Peggo 服务，并自动同步关键配置文件

# 注意：不使用 set -e，因为我们需要处理多个节点的错误而不中断循环

# 配置
# 脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Ansible 目录
ANSIBLE_DIR="$SCRIPT_DIR/ansible"
cd "$ANSIBLE_DIR"
INVENTORY_FILE="$ANSIBLE_DIR/inventory.yml"
CONFIG_DIR="$SCRIPT_DIR/chain-deploy-config"
PEGGO_HOME="/home/ubuntu/.peggo"  # Peggo 主目录

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 打印函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 显示使用说明
show_usage() {
    cat << EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
节点控制脚本 - Biyachain Node Control
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

用法:
    $0 <action> <service> <node> [options]

参数:
    action          操作类型 ( start | stop | restart | status )
    service         服务类型 ( node | peggo | all )
    node            节点名称 ( validator-0 | sentry-0 | all )

选项:
    --sync-keys     启动前同步私钥文件 (默认启用)
    --no-sync-keys  启动前不同步私钥文件
    --force         强制停止 (使用 kill -9)

服务说明:
    node            仅操作区块链节点服务 (biyachaind)
    peggo           仅操作 Peggo 服务 (仅 validator 节点)
    all             同时操作节点和 Peggo 服务
EOF
}

# 获取节点信息
get_node_info() {
    local node=$1
    
    # 解析节点类型和索引
    if [[ $node =~ ^validator-([0-9]+)$ ]]; then
        NODE_TYPE="validator"
        NODE_INDEX="${BASH_REMATCH[1]}"
    elif [[ $node =~ ^sentry-([0-9]+)$ ]]; then
        NODE_TYPE="sentry"
        NODE_INDEX="${BASH_REMATCH[1]}"
    else
        log_error "无效的节点名称: $node"
        return 1
    fi
    
    # 从 inventory.yml 获取 IP 地址 (支持不同缩进级别)
    NODE_IP=$(grep -A 5 "$node:" "$INVENTORY_FILE" | grep "ansible_host:" | awk '{print $2}' | head -1 || echo "")
    
    if [ -z "$NODE_IP" ]; then
        log_error "无法从 inventory.yml 中找到节点 $node 的 IP 地址"
        return 1
    fi
    
    # 确定配置文件路径
    if [ "$NODE_TYPE" == "validator" ]; then
        CONFIG_PATH="$CONFIG_DIR/validator-$NODE_INDEX/config"
    else
        CONFIG_PATH="$CONFIG_DIR/sentry-$NODE_INDEX/config"
    fi
    
    if [ ! -d "$CONFIG_PATH" ]; then
        log_error "配置目录不存在: $CONFIG_PATH"
        return 1
    fi
    
    return 0
}

# 同步节点私钥文件到目标服务器
sync_node_keys() {
    local node=$1
    
    log_info "同步节点私钥文件到 $node ($NODE_IP)..."
    
    # 检查必需的文件
    local node_key="$CONFIG_PATH/node_key.json"
    
    if [ ! -f "$node_key" ]; then
        log_error "node_key.json 不存在: $node_key"
        return 1
    fi
    
    # 复制 node_key.json
    log_info "  - 复制 node_key.json"
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$node_key" ubuntu@$NODE_IP:/tmp/node_key.json.tmp || return 1
    
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        ubuntu@$NODE_IP "sudo mv /tmp/node_key.json.tmp /data/biyachain/config/node_key.json && \
        sudo chmod 644 /data/biyachain/config/node_key.json" || return 1
    
    # 如果是 validator，还需要复制 priv_validator_key.json
    if [ "$NODE_TYPE" == "validator" ]; then
        local priv_validator_key="$CONFIG_PATH/priv_validator_key.json"
        
        if [ ! -f "$priv_validator_key" ]; then
            log_error "priv_validator_key.json 不存在: $priv_validator_key"
            return 1
        fi
        
        log_info "  - 复制 priv_validator_key.json"
        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "$priv_validator_key" ubuntu@$NODE_IP:/tmp/priv_validator_key.json.tmp || return 1
        
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            ubuntu@$NODE_IP "sudo mv /tmp/priv_validator_key.json.tmp /data/biyachain/config/priv_validator_key.json && \
            sudo chmod 600 /data/biyachain/config/priv_validator_key.json" || return 1
    fi
    
    log_success "节点私钥文件同步完成"
    return 0
}

# 同步 Peggo 配置文件到目标服务器
sync_peggo_keys() {
    local node=$1
    
    # Peggo 只在 validator 节点上运行
    if [ "$NODE_TYPE" != "validator" ]; then
        log_warn "Peggo 仅在 validator 节点上运行，跳过"
        return 0
    fi
    
    log_info "同步 Peggo 配置文件到 $node ($NODE_IP)..."
    
    # 确定 .env 文件路径（在 validators 目录下）
    local env_file="$CONFIG_DIR/validator-$NODE_INDEX/.env"
    
    if [ ! -f "$env_file" ]; then
        log_error ".env 文件不存在: $env_file"
        log_error "请先运行: ansible-playbook -i inventory.yml playbooks/generate-peggo-env.yml"
        return 1
    fi
    
    log_info "  - 上传 .env 文件"
    
    # 上传 .env 文件到远程服务器
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$env_file" ubuntu@$NODE_IP:/tmp/peggo.env.tmp || {
        log_error "上传 .env 文件失败"
        return 1
    }
    
    # 创建 peggo 目录并移动文件
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        ubuntu@$NODE_IP "mkdir -p $PEGGO_HOME && \
        mv /tmp/peggo.env.tmp $PEGGO_HOME/.env && \
        chmod 600 $PEGGO_HOME/.env" || {
        log_error "配置 .env 文件失败"
        return 1
    }
    
    log_success "Peggo 配置文件同步完成"
    return 0
}

# 停止节点
stop_node() {
    local node=$1
    local force=${2:-false}
    
    log_info "停止节点 $node ($NODE_IP)..."
    
    if [ "$force" == "true" ]; then
        log_warn "使用强制模式停止"
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            ubuntu@$NODE_IP "sudo systemctl stop biyachaind; sudo pkill -9 biyachaind || true" || {
            log_error "停止节点失败"
            return 1
        }
    else
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            ubuntu@$NODE_IP "sudo systemctl stop biyachaind" || {
            log_error "停止节点失败"
            return 1
        }
    fi
    
    # 等待进程完全停止
    sleep 2
    
    # 确认进程已停止
    local is_running=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        ubuntu@$NODE_IP "pgrep -x biyachaind > /dev/null && echo 'yes' || echo 'no'")
    
    if [ "$is_running" == "yes" ]; then
        log_warn "节点进程仍在运行，强制终止..."
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            ubuntu@$NODE_IP "sudo pkill -9 biyachaind || true"
        sleep 1
    fi
    
    log_success "节点已停止"
    return 0
}

# 启动节点
start_node() {
    local node=$1
    local sync_keys_flag=${2:-true}
    
    log_info "启动节点 $node ($NODE_IP)..."
    
    # 同步私钥文件
    if [ "$sync_keys_flag" == "true" ]; then
        sync_node_keys "$node" || return 1
    else
        log_warn "跳过私钥文件同步"
    fi
    
    # 启动服务
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        ubuntu@$NODE_IP "sudo systemctl start biyachaind" || {
        log_error "启动节点失败"
        return 1
    }
    
    # 等待服务启动
    sleep 3
    
    # 检查服务状态
    local status=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        ubuntu@$NODE_IP "sudo systemctl is-active biyachaind" || echo "failed")
    
    if [ "$status" == "active" ]; then
        log_success "节点已启动"
        
        # 显示区块高度
        sleep 2
        local height=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            ubuntu@$NODE_IP "curl -s http://localhost:26757/status 2>/dev/null | jq -r '.result.sync_info.latest_block_height' 2>/dev/null" || echo "N/A")
        log_info "当前区块高度: $height"
        
        # 等待节点稳定后删除敏感文件
        if [ "$sync_keys_flag" == "true" ]; then
            log_info "等待节点稳定 (5秒)..."
            sleep 5
            log_info "删除远程敏感密钥文件..."
            ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                ubuntu@$NODE_IP "rm -f /data/biyachain/config/node_key.json /data/biyachain/config/priv_validator_key.json" 2>/dev/null || true
            log_success "敏感文件已删除"
        fi
    else
        log_error "节点启动失败，状态: $status"
        log_info "查看日志: ssh ubuntu@$NODE_IP 'sudo journalctl -u biyachaind -n 50'"
        return 1
    fi
    
    return 0
}

# 停止 Peggo 服务
stop_peggo() {
    local node=$1
    local force=${2:-false}
    
    # Peggo 只在 validator 节点上运行
    if [ "$NODE_TYPE" != "validator" ]; then
        log_warn "Peggo 仅在 validator 节点上运行，跳过"
        return 0
    fi
    
    log_info "停止 Peggo 服务 $node ($NODE_IP)..."
    
    if [ "$force" == "true" ]; then
        log_warn "使用强制模式停止"
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            ubuntu@$NODE_IP "sudo systemctl stop peggo; sudo pkill -9 peggo || true" || {
            log_error "停止 Peggo 失败"
            return 1
        }
    else
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            ubuntu@$NODE_IP "sudo systemctl stop peggo" || {
            log_error "停止 Peggo 失败"
            return 1
        }
    fi
    
    # 等待进程完全停止
    sleep 2
    
    # 确认进程已停止
    local is_running=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        ubuntu@$NODE_IP "pgrep -x peggo > /dev/null && echo 'yes' || echo 'no'")
    
    if [ "$is_running" == "yes" ]; then
        log_warn "Peggo 进程仍在运行，强制终止..."
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            ubuntu@$NODE_IP "sudo pkill -9 peggo || true"
        sleep 1
    fi
    
    log_success "Peggo 已停止"
    return 0
}

# 启动 Peggo 服务
start_peggo() {
    local node=$1
    local sync_keys_flag=${2:-true}
    
    # Peggo 只在 validator 节点上运行
    if [ "$NODE_TYPE" != "validator" ]; then
        log_warn "Peggo 仅在 validator 节点上运行，跳过"
        return 0
    fi
    
    log_info "启动 Peggo 服务 $node ($NODE_IP)..."
    
    # 同步私钥和配置文件
    if [ "$sync_keys_flag" == "true" ]; then
        sync_peggo_keys "$node" || return 1
    else
        log_warn "跳过 Peggo 配置文件同步"
    fi
    
    # 启动服务
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        ubuntu@$NODE_IP "sudo systemctl start peggo" || {
        log_error "启动 Peggo 失败"
        return 1
    }
    
    # 等待服务启动
    sleep 3
    
    # 检查服务状态
    local status=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        ubuntu@$NODE_IP "sudo systemctl is-active peggo" || echo "failed")
    
    if [ "$status" == "active" ]; then
        log_success "Peggo 已启动"
        
        # 等待 Peggo 完成初始化后删除 .env 文件
        if [ "$sync_keys_flag" == "true" ]; then
            log_info "等待 Peggo 完成初始化 (10秒)..."
            sleep 10
            log_info "删除远程 .env 文件..."
            ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                ubuntu@$NODE_IP "rm -f $PEGGO_HOME/.env" 2>/dev/null || true
            log_success ".env 文件已删除"
        fi
    else
        log_error "Peggo 启动失败，状态: $status"
        log_info "查看日志: ssh ubuntu@$NODE_IP 'sudo journalctl -u peggo -n 50'"
        return 1
    fi
    
    return 0
}

# 重启 Peggo 服务
restart_peggo() {
    local node=$1
    local sync_keys_flag=${2:-true}
    
    # Peggo 只在 validator 节点上运行
    if [ "$NODE_TYPE" != "validator" ]; then
        log_warn "Peggo 仅在 validator 节点上运行，跳过"
        return 0
    fi
    
    log_info "重启 Peggo 服务 $node ($NODE_IP)..."
    
    stop_peggo "$node" false || return 1
    sleep 2
    start_peggo "$node" "$sync_keys_flag" || return 1
    
    log_success "Peggo 重启完成"
    return 0
}

# 查看 Peggo 服务状态
status_peggo() {
    local node=$1
    
    # Peggo 只在 validator 节点上运行
    if [ "$NODE_TYPE" != "validator" ]; then
        log_warn "Peggo 仅在 validator 节点上运行，跳过"
        return 0
    fi
    
    log_info "查询 Peggo 服务状态 $node ($NODE_IP)..."
    echo ""
    
    # 服务状态
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Peggo 服务状态:"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        ubuntu@$NODE_IP "sudo systemctl status peggo --no-pager -l" || true
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "最近日志 (最后 30 行):"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        ubuntu@$NODE_IP "sudo journalctl -u peggo -n 30 --no-pager" || true
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "配置文件检查:"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        ubuntu@$NODE_IP "ls -la $PEGGO_HOME/.env 2>/dev/null || echo '.env 文件不存在'" || true
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    return 0
}

# 重启节点
restart_node() {
    local node=$1
    local sync_keys_flag=${2:-true}
    
    log_info "重启节点 $node ($NODE_IP)..."
    
    stop_node "$node" false || return 1
    sleep 2
    start_node "$node" "$sync_keys_flag" || return 1
    
    log_success "节点重启完成"
    return 0
}

# 查看节点状态
status_node() {
    local node=$1
    
    log_info "查询节点状态 $node ($NODE_IP)..."
    echo ""
    
    # 服务状态
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "服务状态:"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        ubuntu@$NODE_IP "sudo systemctl status biyachaind --no-pager -l" || true
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "区块链状态:"
    
    local status_json=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        ubuntu@$NODE_IP "curl -s http://localhost:26757/status 2>/dev/null" || echo "{}")
    
    if [ -n "$status_json" ] && [ "$status_json" != "{}" ]; then
        echo "$status_json" | jq '{
            node_id: .result.node_info.id,
            moniker: .result.node_info.moniker,
            network: .result.node_info.network,
            height: .result.sync_info.latest_block_height,
            time: .result.sync_info.latest_block_time,
            catching_up: .result.sync_info.catching_up,
            voting_power: .result.validator_info.voting_power
        }' 2>/dev/null || echo "无法解析状态"
    else
        echo "节点 RPC 不可用"
    fi
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    return 0
}

# 获取所有节点列表
get_all_nodes() {
    # 支持 2 个或 4 个空格的缩进
    grep -E "^ {2,4}(validator|sentry)-[0-9]+:" "$INVENTORY_FILE" | sed 's/://g' | awk '{print $1}'
}

# 主函数
main() {
    if [ $# -lt 3 ]; then
        show_usage
        exit 1
    fi
    
    ACTION=$1
    SERVICE=$2
    NODE=$3
    SYNC_KEYS=true
    FORCE=false
    
    # 解析选项
    shift 3
    while [[ $# -gt 0 ]]; do
        case $1 in
            --sync-keys)
                SYNC_KEYS=true
                shift
                ;;
            --no-sync-keys)
                SYNC_KEYS=false
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            *)
                log_error "未知选项: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # 检查配置目录
    if [ ! -d "$CONFIG_DIR" ]; then
        log_error "配置目录不存在: $CONFIG_DIR"
        log_info "请先运行: sh generate_config.sh"
        exit 1
    fi
    
    # 处理 all 节点
    if [ "$NODE" == "all" ]; then
        log_info "操作所有节点..."
        ALL_NODES=$(get_all_nodes)
        
        if [ -z "$ALL_NODES" ]; then
            log_error "未找到任何节点"
            exit 1
        fi
        
        SUCCESS_COUNT=0
        FAIL_COUNT=0
        
        for node in $ALL_NODES; do
            echo ""
            log_info "处理节点: $node"
            
            if ! get_node_info "$node"; then
                ((FAIL_COUNT++))
                continue
            fi
            
            # 根据服务类型执行操作
            case $SERVICE in
                node)
                    case $ACTION in
                        start)
                            if start_node "$node" "$SYNC_KEYS"; then
                                ((SUCCESS_COUNT++))
                            else
                                ((FAIL_COUNT++))
                            fi
                            ;;
                        stop)
                            if stop_node "$node" "$FORCE"; then
                                ((SUCCESS_COUNT++))
                            else
                                ((FAIL_COUNT++))
                            fi
                            ;;
                        restart)
                            if restart_node "$node" "$SYNC_KEYS"; then
                                ((SUCCESS_COUNT++))
                            else
                                ((FAIL_COUNT++))
                            fi
                            ;;
                        status)
                            if status_node "$node"; then
                                ((SUCCESS_COUNT++))
                            else
                                ((FAIL_COUNT++))
                            fi
                            ;;
                        *)
                            log_error "未知操作: $ACTION"
                            show_usage
                            exit 1
                            ;;
                    esac
                    ;;
                peggo)
                    case $ACTION in
                        start)
                            if start_peggo "$node" "$SYNC_KEYS"; then
                                ((SUCCESS_COUNT++))
                            else
                                ((FAIL_COUNT++))
                            fi
                            ;;
                        stop)
                            if stop_peggo "$node" "$FORCE"; then
                                ((SUCCESS_COUNT++))
                            else
                                ((FAIL_COUNT++))
                            fi
                            ;;
                        restart)
                            if restart_peggo "$node" "$SYNC_KEYS"; then
                                ((SUCCESS_COUNT++))
                            else
                                ((FAIL_COUNT++))
                            fi
                            ;;
                        status)
                            if status_peggo "$node"; then
                                ((SUCCESS_COUNT++))
                            else
                                ((FAIL_COUNT++))
                            fi
                            ;;
                        *)
                            log_error "未知操作: $ACTION"
                            show_usage
                            exit 1
                            ;;
                    esac
                    ;;
                all)
                    case $ACTION in
                        start)
                            if start_node "$node" "$SYNC_KEYS" && start_peggo "$node" "$SYNC_KEYS"; then
                                ((SUCCESS_COUNT++))
                            else
                                ((FAIL_COUNT++))
                            fi
                            ;;
                        stop)
                            if stop_peggo "$node" "$FORCE" && stop_node "$node" "$FORCE"; then
                                ((SUCCESS_COUNT++))
                            else
                                ((FAIL_COUNT++))
                            fi
                            ;;
                        restart)
                            if restart_node "$node" "$SYNC_KEYS" && restart_peggo "$node" "$SYNC_KEYS"; then
                                ((SUCCESS_COUNT++))
                            else
                                ((FAIL_COUNT++))
                            fi
                            ;;
                        status)
                            if status_node "$node" && status_peggo "$node"; then
                                ((SUCCESS_COUNT++))
                            else
                                ((FAIL_COUNT++))
                            fi
                            ;;
                        *)
                            log_error "未知操作: $ACTION"
                            show_usage
                            exit 1
                            ;;
                    esac
                    ;;
                *)
                    log_error "未知服务类型: $SERVICE"
                    show_usage
                    exit 1
                    ;;
            esac
            
            sleep 1
        done
        
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "操作完成: 成功 $SUCCESS_COUNT, 失败 $FAIL_COUNT"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        if [ $FAIL_COUNT -gt 0 ]; then
            exit 1
        fi
        
        exit 0
    fi
    
    # 处理单个节点
    if ! get_node_info "$NODE"; then
        exit 1
    fi
    
    # 根据服务类型执行操作
    case $SERVICE in
        node)
            case $ACTION in
                start)
                    start_node "$NODE" "$SYNC_KEYS"
                    ;;
                stop)
                    stop_node "$NODE" "$FORCE"
                    ;;
                restart)
                    restart_node "$NODE" "$SYNC_KEYS"
                    ;;
                status)
                    status_node "$NODE"
                    ;;
                *)
                    log_error "未知操作: $ACTION"
                    show_usage
                    exit 1
                    ;;
            esac
            ;;
        peggo)
            case $ACTION in
                start)
                    start_peggo "$NODE" "$SYNC_KEYS"
                    ;;
                stop)
                    stop_peggo "$NODE" "$FORCE"
                    ;;
                restart)
                    restart_peggo "$NODE" "$SYNC_KEYS"
                    ;;
                status)
                    status_peggo "$NODE"
                    ;;
                *)
                    log_error "未知操作: $ACTION"
                    show_usage
                    exit 1
                    ;;
            esac
            ;;
        all)
            case $ACTION in
                start)
                    start_node "$NODE" "$SYNC_KEYS" && start_peggo "$NODE" "$SYNC_KEYS"
                    ;;
                stop)
                    stop_peggo "$NODE" "$FORCE" && stop_node "$NODE" "$FORCE"
                    ;;
                restart)
                    restart_node "$NODE" "$SYNC_KEYS" && restart_peggo "$NODE" "$SYNC_KEYS"
                    ;;
                status)
                    status_node "$NODE" && status_peggo "$NODE"
                    ;;
                *)
                    log_error "未知操作: $ACTION"
                    show_usage
                    exit 1
                    ;;
            esac
            ;;
        *)
            log_error "未知服务类型: $SERVICE"
            show_usage
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@"

