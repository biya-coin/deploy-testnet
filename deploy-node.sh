#!/bin/bash

set -e

# 解析参数
LIMIT_HOST=""       # 默认部署所有节点
CLEAN_DATA=true     # 默认清空数据（完全重新部署）
NODES_ONLY=false    # 仅部署节点
PEGGO_ONLY=false    # 仅部署跨链桥
REGISTER_ONLY=false # 仅执行注册（跳过部署）

while [[ $# -gt 0 ]]; do
    case $1 in
        --host)
            LIMIT_HOST="$2"
            shift 2
            ;;
        --no-clean)
            CLEAN_DATA=false
            shift
            ;;
        --node)
            NODES_ONLY=true
            shift
            ;;
        --peggo)
            PEGGO_ONLY=true
            shift
            ;;
        --nodes-only)
            # 保留旧参数兼容性
            NODES_ONLY=true
            shift
            ;;
        --register-only)
            REGISTER_ONLY=true
            shift
            ;;
        --help)
            echo "用法: $0 [选项]"
            echo ""
            echo "选项:"
            echo "  --host <节点名>    部署指定节点（如 validator-0, sentry-0）"
            echo "                     指定此选项时，仅部署该节点，不执行 Peggo 和注册"
            echo "  --node             仅部署节点服务，不部署 Peggo 和注册"
            echo "  --peggo            仅部署 Peggo 跨链桥，不部署节点（需要节点已运行）"
            echo "  --register-only    仅执行 orchestrator 注册（跳过节点和 Peggo 部署）"
            echo "  --no-clean         不清空数据（仅更新二进制和配置）"
            echo "                     默认会清空 /data/biyachain 完全重新部署"
            echo "  --help             显示帮助信息"
            echo ""
            echo "示例:"
            echo "  $0                      完整部署流程（节点 → 注册 → Peggo）"
            echo "  $0 --node               仅部署所有节点"
            echo "  $0 --peggo              仅部署 Peggo 跨链桥"
            echo "  $0 --host validator-0   仅部署 validator-0 节点"
            echo "  $0 --register-only      仅注册 orchestrator"
            echo ""
            echo "⚠️  注意："
            echo "  默认模式会删除 /data/biyachain 目录（包括数据和配置）"
            echo "  这会导致链从创世区块重新开始"
            exit 0
            ;;
        *)
            echo "错误: 未知参数 $1"
            echo "使用 --help 查看帮助"
            exit 1
            ;;
    esac
done

# 脚本目录
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Ansible 目录
ANSIBLE_DIR="$SCRIPT_DIR/ansible"
cd "$ANSIBLE_DIR"

# 检查 inventory.yml 是否存在
if [ ! -f "inventory.yml" ]; then
    echo "错误: inventory.yml 文件不存在"
    exit 1
fi

# 检查 deploy-full.yml 是否存在
if [ ! -f "playbooks/deploy-full.yml" ]; then
    echo "错误: playbooks/deploy-full.yml 文件不存在"
    exit 1
fi

# 检查二进制文件目录（相对于项目根目录）
BINARY_DIR="$SCRIPT_DIR/build/bin"
# 转换为绝对路径
BINARY_DIR_ABS=$(cd "$BINARY_DIR" 2>/dev/null && pwd || echo "")
if [ -z "$BINARY_DIR_ABS" ] || [ ! -d "$BINARY_DIR_ABS" ]; then
    echo "错误: 二进制文件目录不存在: $BINARY_DIR"
    echo "请先运行 ./compile.sh 在本地编译"
    exit 1
fi

# 检查必需的二进制文件
REQUIRED_BINARIES=("biyachaind" "peggo" "cosmovisor" "libwasmvm.x86_64.so")
MISSING_BINARIES=()

for binary in "${REQUIRED_BINARIES[@]}"; do
    if [ ! -f "$BINARY_DIR_ABS/$binary" ]; then
        MISSING_BINARIES+=("$binary")
    fi
done

if [ ${#MISSING_BINARIES[@]} -gt 0 ]; then
    echo "错误: 缺少以下二进制文件:"
    for binary in "${MISSING_BINARIES[@]}"; do
        echo "  - $BINARY_DIR_ABS/$binary"
    done
    echo ""
    echo "请先运行 ./compile.sh 在本地编译"
    exit 1
fi

# 检查配置文件目录（相对于项目根目录）
CONFIG_DIR="$SCRIPT_DIR/chain-deploy-config"
# 转换为绝对路径
CONFIG_DIR_ABS=$(cd "$CONFIG_DIR" 2>/dev/null && pwd || echo "$CONFIG_DIR")
if [ ! -d "$CONFIG_DIR_ABS" ]; then
    echo "错误: 配置文件目录不存在: $CONFIG_DIR_ABS"
    echo "请先运行 ./generate_config.sh 生成配置文件"
    exit 1
fi

echo ""
echo "=========================================="
echo "           节点部署脚本"
echo "=========================================="
echo ""
if [ "$CLEAN_DATA" == true ]; then
            echo "部署模式: 完全重新部署（清空数据）"
else
    echo "部署模式: 仅更新（保留数据）"
fi

# 判断部署范围
if [ "$REGISTER_ONLY" == true ]; then
    echo "部署范围: 仅注册 Orchestrator（跳过节点和 Peggo 部署）"
elif [ "$PEGGO_ONLY" == true ]; then
    echo "部署范围: 仅部署 Peggo 跨链桥（跳过节点部署和注册）"
elif [ -n "$LIMIT_HOST" ]; then
    echo "部署范围: 仅 $LIMIT_HOST（不包含 Peggo 和注册）"
elif [ "$NODES_ONLY" == true ]; then
    echo "部署范围: 仅所有节点（不包含 Peggo 和注册）"
else
    echo "部署范围: 完整流程（节点 → 注册 → Peggo）"
    echo "           ✅ 优化：先注册后启动 Peggo，确保 Validator 模式"
fi

echo "二进制文件目录: $BINARY_DIR_ABS"
echo "配置文件目录: $CONFIG_DIR_ABS"
echo "=========================================="
echo ""

# 检查 ansible 是否安装
if ! command -v ansible-playbook &> /dev/null; then
    echo "错误: ansible-playbook 未安装"
    echo "请运行: pip3 install ansible"
    exit 1
fi

# 检测是否需要密码认证
echo "检测 SSH 认证方式..."
NEED_PASSWORD=false

# 测试第一个非 localhost 主机的连接
TEST_HOST=$(ansible-inventory -i inventory.yml --list 2>/dev/null | python3 -c "
import sys, json
inv = json.load(sys.stdin)
all_hosts = inv.get('_meta', {}).get('hostvars', {})
for host, vars in all_hosts.items():
    if host != 'localhost':
        print(host)
        break
" 2>/dev/null)

if [ -n "$TEST_HOST" ]; then
    # 尝试无密码连接
    set +e  # 临时关闭 set -e，避免 ping 失败导致脚本退出
    PING_OUTPUT=$(ansible $TEST_HOST -i inventory.yml -m ping -o 2>&1)
    PING_EXIT_CODE=$?
    set -e  # 重新启用 set -e
    
    if [ $PING_EXIT_CODE -eq 0 ]; then
        echo "✅ 检测到 SSH 公钥认证（无需密码）"
        NEED_PASSWORD=false
    else
        # 检查是否是连接超时或主机不可达
        if echo "$PING_OUTPUT" | grep -q "UNREACHABLE\|timed out\|Connection refused"; then
            echo "❌ 错误: 无法连接到测试主机 $TEST_HOST"
            echo "详细错误信息:"
            echo "$PING_OUTPUT"
            exit 1
        fi
        
        echo "⚠️  未检测到公钥认证，将使用密码认证"
        NEED_PASSWORD=true
        
        # 检查 sshpass 是否安装（用于密码认证）
        if ! command -v sshpass &> /dev/null; then
            echo ""
            echo "错误: sshpass 未安装，密码认证需要此工具"
            echo "请运行: sudo apt-get install sshpass"
            exit 1
        fi
    fi
else
    echo "⚠️  无法检测认证方式，默认尝试密码认证"
    NEED_PASSWORD=true
fi

echo ""

# 列出将要部署的主机
echo "=========================================="
if [ -n "$LIMIT_HOST" ]; then
    echo "将要部署的服务器: $LIMIT_HOST"
else
    echo "将要部署的服务器列表:"
fi
echo "=========================================="

# 使用 ansible-inventory 获取主机列表
if [ -n "$LIMIT_HOST" ]; then
    # 显示指定的主机
    ansible-inventory -i inventory.yml --host "$LIMIT_HOST" 2>/dev/null | python3 -c "
import sys, json
try:
    host_vars = json.load(sys.stdin)
    node_type = host_vars.get('node_type', 'unknown')
    node_index = host_vars.get('node_index', '?')
    ip = host_vars.get('ansible_host', 'unknown')
    node_type_desc = '共识节点' if node_type == 'validator' else '哨兵节点'
    print(f'  - {node_type}-{node_index} ({node_type_desc}) - IP: {ip}')
except:
    print(f'  - 无法获取主机信息')
" || echo "  - 错误: 主机 '$LIMIT_HOST' 不存在"
else
    # 显示所有主机
    ansible-inventory -i inventory.yml --list 2>/dev/null | python3 -c "
import sys, json
inv = json.load(sys.stdin)
all_hosts = inv.get('_meta', {}).get('hostvars', {})
for host, vars in sorted(all_hosts.items()):
    if host == 'localhost':
        continue
    node_type = vars.get('node_type', 'unknown')
    node_index = vars.get('node_index', '?')
    ip = vars.get('ansible_host', 'unknown')
    node_type_desc = '共识节点' if node_type == 'validator' else '哨兵节点'
    print(f'  - {node_type}-{node_index} ({node_type_desc}) - IP: {ip}')
" || echo "无法读取主机列表"
fi

echo "=========================================="
echo ""

# 初始化主机列表（所有模式都需要）
if [ -n "$LIMIT_HOST" ]; then
    # 如果指定了主机，只部署该主机
    HOSTS="$LIMIT_HOST"
else
    # 否则获取所有主机
    HOSTS=$(python3 -c "
import sys
try:
    import yaml
    with open('inventory.yml') as f:
        inv = yaml.safe_load(f)
    hosts = []
    for group in ['validators', 'sentries']:
        if group in inv.get('all', {}).get('children', {}):
            hosts_dict = inv['all']['children'][group].get('hosts', {})
            hosts.extend(hosts_dict.keys())
    if hosts:
        hosts.sort(key=lambda x: (0 if x.startswith('validator') else 1, int(x.split('-')[1])))
        print(' '.join(hosts))
except:
    pass
" 2>/dev/null)

    if [ -z "$HOSTS" ]; then
        HOSTS=$(grep -E '^\s+(validator|sentry)-[0-9]+:' inventory.yml | sed 's/.*\(\(validator\|sentry\)-[0-9]*\):.*/\1/' | sort -t- -k1,1 -k2,2n)
    fi
fi

# 提取 validator 主机列表（用于注册和 Peggo 部署）
VALIDATOR_HOSTS=$(echo "$HOSTS" | tr ' ' '\n' | grep "^validator-" || true)

# 如果是仅注册模式或仅 Peggo 模式，设置跳转标志
if [ "$REGISTER_ONLY" == true ]; then
    echo "跳过节点和 Peggo 部署，直接执行注册..."
    echo ""
    SKIP_TO_REGISTER=true
    SKIP_TO_PEGGO=false
elif [ "$PEGGO_ONLY" == true ]; then
    echo "跳过节点部署和注册，直接部署 Peggo..."
    echo ""
    SKIP_TO_REGISTER=false
    SKIP_TO_PEGGO=true
else
    SKIP_TO_REGISTER=false
    SKIP_TO_PEGGO=false
fi

# 如果需要清空数据，先执行清空操作（仅 Peggo 模式不需要清空）
if [ "$CLEAN_DATA" == true ] && [ "$SKIP_TO_REGISTER" == false ] && [ "$SKIP_TO_PEGGO" == false ]; then
    echo "=========================================="
    echo "步骤 1/2: 清空节点数据"
    echo "=========================================="
    echo ""
    echo "⚠️  警告: 即将删除所有节点的 /data/biyachain 目录"
    echo "   这将删除所有区块数据、配置文件和数据库"
    echo "   链将从创世区块重新开始"
    echo ""
    
    if [ -n "$LIMIT_HOST" ]; then
        echo "目标节点: $LIMIT_HOST"
    else
        echo "目标节点: 所有节点"
    fi
    
    echo ""
    echo "按 Enter 继续，或按 Ctrl+C 取消..."
    read -r
    
    # 停止所有服务（使用 node-control.sh）
    echo "正在停止所有服务（节点 + Peggo）..."
    
    NODE_CONTROL_SCRIPT="$SCRIPT_DIR/node-control.sh"
    if [ -f "$NODE_CONTROL_SCRIPT" ]; then
        # 正确的参数格式: ./bin/node-control.sh <action> <service> <node>
        if [ -n "$LIMIT_HOST" ]; then
            # 停止指定节点的所有服务
            "$NODE_CONTROL_SCRIPT" stop all "$LIMIT_HOST"
        else
            # 停止所有节点的所有服务
            "$NODE_CONTROL_SCRIPT" stop all all
        fi
        STOP_EXIT_CODE=$?
        
        if [ $STOP_EXIT_CODE -eq 0 ]; then
            echo "✓ 所有服务已停止（节点 + Peggo）"
        else
            echo "⚠️  停止服务时出现问题（退出码: $STOP_EXIT_CODE）"
            echo "   将继续清空数据"
        fi
    else
        echo "⚠️  未找到 node-control.sh 脚本: $NODE_CONTROL_SCRIPT"
        echo "   跳过停止服务步骤"
    fi
    
    echo "正在清空数据..."
    
    if [ -n "$LIMIT_HOST" ]; then
        # 清空指定节点
        if [ "$NEED_PASSWORD" == true ]; then
            ansible "$LIMIT_HOST" -i inventory.yml -m shell \
                -a "sudo rm -rf /data/biyachain" \
                --ask-pass --ask-become-pass --become
        else
            ansible "$LIMIT_HOST" -i inventory.yml -m shell \
                -a "sudo rm -rf /data/biyachain" \
                --become
        fi
    else
        # 清空所有节点
        if [ "$NEED_PASSWORD" == true ]; then
            ansible all -i inventory.yml -m shell \
                -a "sudo rm -rf /data/biyachain" \
                --ask-pass --ask-become-pass --become
        else
            ansible all -i inventory.yml -m shell \
                -a "sudo rm -rf /data/biyachain" \
                --become
        fi
    fi
    
    CLEAN_EXIT_CODE=$?
    if [ $CLEAN_EXIT_CODE -eq 0 ]; then
        echo ""
        echo "✓ 数据清空完成"
        echo ""
    else
        echo ""
        echo "❌ 数据清空失败（退出码: $CLEAN_EXIT_CODE）"
        echo "是否继续部署? (y/N)"
        read -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "部署已取消"
            exit 1
        fi
    fi
fi

# ==========================================
# 阶段 1: 部署所有节点（不部署 Peggo）
# ==========================================
if [ "$SKIP_TO_REGISTER" == false ] && [ "$SKIP_TO_PEGGO" == false ]; then
    echo "=========================================="
    if [ "$CLEAN_DATA" == true ]; then
        echo "阶段 1/4: 部署所有节点"
    else
        echo "阶段 1/4: 部署所有节点（更新模式）"
    fi
    echo "=========================================="
    echo ""

for host in $HOSTS; do
    # 获取服务器IP
    HOST_IP=$(grep -A 3 "^[[:space:]]*${host}:" inventory.yml | grep "ansible_host:" | awk '{print $2}' | tr -d '"' || echo "未知")
    
    if echo "$host" | grep -q "validator"; then
        NODE_TYPE_DESC="共识节点"
    else
        NODE_TYPE_DESC="哨兵节点"
    fi
    
    echo ""
    echo "=========================================="
    echo "准备部署: $host ($NODE_TYPE_DESC)"
    echo "服务器IP: ${HOST_IP}"
    echo "=========================================="
    echo ""
    
    if [ "$NEED_PASSWORD" == true ]; then
        echo "⚠️  接下来将要求您输入此服务器的密码"
        echo "  - SSH password: 用于连接到 ${HOST_IP}"
        echo "  - BECOME password: 用于执行 sudo 操作（如果与 SSH 密码相同，直接按回车）"
        echo ""
    fi
    
    # 构建 ansible-playbook 命令 - 仅部署节点，不部署 Peggo
    if [ "$NEED_PASSWORD" == true ]; then
        ANSIBLE_CMD="ansible-playbook -i inventory.yml playbooks/deploy-full.yml \
            --limit $host \
            --tags remote_deploy \
            --ask-pass \
            --ask-become-pass \
            -e deploy_peggy_contract=false \
            -e deploy_peggo=false \
            -e local_config_dir=\"$CONFIG_DIR_ABS\" \
            -e local_binary_dir=\"$BINARY_DIR_ABS\""
    else
        ANSIBLE_CMD="ansible-playbook -i inventory.yml playbooks/deploy-full.yml \
            --limit $host \
            --tags remote_deploy \
            --become \
            -e deploy_peggy_contract=false \
            -e deploy_peggo=false \
            -e local_config_dir=\"$CONFIG_DIR_ABS\" \
            -e local_binary_dir=\"$BINARY_DIR_ABS\""
    fi
    
    # 执行部署（支持密码重试）
    MAX_RETRIES=5
    RETRY_COUNT=0
    DEPLOY_SUCCESS=false
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ "$DEPLOY_SUCCESS" != true ]; do
        eval $ANSIBLE_CMD "$@"
        DEPLOY_EXIT_CODE=$?
        
        if [ $DEPLOY_EXIT_CODE -eq 0 ]; then
            DEPLOY_SUCCESS=true
            echo ""
            echo "✓ $host 部署完成"
        elif [ $DEPLOY_EXIT_CODE -eq 4 ]; then
            RETRY_COUNT=$((RETRY_COUNT + 1))
            if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                echo ""
                echo "⚠️  连接失败（可能是密码错误）"
                echo "   剩余重试次数: $((MAX_RETRIES - RETRY_COUNT))"
                echo ""
                echo "请重新输入正确的密码："
                sleep 1
                continue
            else
                echo ""
                echo "❌ $host 连接失败（已重试 $MAX_RETRIES 次）"
                echo ""
                echo "是否继续部署其他服务器? (y/N)"
                read -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    echo "部署已中断"
                    exit 1
                fi
                break
            fi
        else
            RETRY_COUNT=$((RETRY_COUNT + 1))
            if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                echo ""
                echo "⚠️  $host 部署失败（退出码: $DEPLOY_EXIT_CODE，剩余重试次数: $((MAX_RETRIES - RETRY_COUNT))）"
                echo "是否重试? (Y/n)"
                read -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                    continue
                else
                    break
                fi
            else
                echo ""
                echo "❌ $host 部署失败（已重试 $MAX_RETRIES 次）"
                echo "是否继续部署其他服务器? (y/N)"
                read -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    echo "部署已中断"
                    exit 1
                fi
            fi
        fi
    done
done

    echo "=========================================="
    echo "✓ 阶段 1 完成：所有节点部署完成"
    echo "=========================================="
    echo ""
fi  # 结束 SKIP_TO_REGISTER == false && SKIP_TO_PEGGO == false

# 如果指定了 --host 或 --nodes-only，则到此结束
if [ -n "$LIMIT_HOST" ] || [ "$NODES_ONLY" == true ]; then
    echo "部署完成！"
    if [ -n "$LIMIT_HOST" ]; then
        echo "（仅部署了 $LIMIT_HOST）"
    else
        echo "（仅部署了节点，未部署 Peggo）"
    fi
    exit 0
fi

# ==========================================
# 阶段 2: 注册 Orchestrator 地址
# ==========================================
if [ "$SKIP_TO_REGISTER" == false ] && [ "$SKIP_TO_PEGGO" == false ]; then
    echo "=========================================="
    echo "阶段 2/4: 准备注册 Orchestrator"
    echo "=========================================="
    echo ""
    echo "提示: 请确保链已正常出块后再继续"
    echo "      可使用 ./bin/node-control.sh status all 检查节点状态"
    echo ""
    echo "等待节点启动并开始出块（30秒）..."
    sleep 30
    echo ""
    
    # 检查节点是否正常出块
    echo "检查节点状态..."
    FIRST_VALIDATOR=$(echo "$VALIDATOR_HOSTS" | tr ' ' '\n' | head -n1)
    if [ -n "$FIRST_VALIDATOR" ]; then
        FIRST_IP=$(grep -A 3 "^[[:space:]]*${FIRST_VALIDATOR}:" inventory.yml | grep "ansible_host:" | awk '{print $2}' | tr -d '"' || echo "")
        if [ -n "$FIRST_IP" ]; then
            echo "正在检查 $FIRST_VALIDATOR ($FIRST_IP) 的 RPC 状态..."
            for i in {1..10}; do
                if curl -s "http://${FIRST_IP}:26757/status" | grep -q "latest_block_height"; then
                    echo "✓ 节点已正常出块"
                    break
                fi
                if [ $i -eq 10 ]; then
                    echo "⚠️  警告: 节点可能未正常出块，但将继续注册流程"
                fi
                sleep 3
            done
        fi
    fi
    echo ""
fi  # 结束 SKIP_TO_REGISTER == false && SKIP_TO_PEGGO == false

if [ "$REGISTER_ONLY" == true ]; then
    echo "=========================================="
    echo "注册 Orchestrator 地址（本地执行）"
    echo "=========================================="
else
    echo "=========================================="
    echo "阶段 2/4: 注册 Orchestrator 地址（本地执行）"
    echo "=========================================="
fi

# 使用本地脚本注册
echo "说明: 使用本地 keyring 和配置文件注册 orchestrator 地址"
echo "      不依赖远程服务器上的私钥文件"

# 获取第一个可用节点的 RPC（从 VALIDATOR_HOSTS）
FIRST_VALIDATOR=$(echo "$VALIDATOR_HOSTS" | tr ' ' '\n' | head -n1)
if [ -z "$FIRST_VALIDATOR" ]; then
    echo "错误: 未找到 validator 节点"
    exit 1
fi

FIRST_IP=$(grep -A 3 "^[[:space:]]*${FIRST_VALIDATOR}:" inventory.yml | grep "ansible_host:" | awk '{print $2}' | tr -d '"' || echo "")
if [ -z "$FIRST_IP" ]; then
    echo "错误: 无法获取节点 IP"
    exit 1
fi

NODE_RPC="http://${FIRST_IP}:26757"
echo "使用节点 RPC: $NODE_RPC"
echo ""

# 使用 Ansible playbook 注册
ansible-playbook -i inventory.yml playbooks/register-local.yml \
    -e node_rpc="$NODE_RPC"

REGISTER_EXIT_CODE=$?

if [ $REGISTER_EXIT_CODE -eq 0 ]; then
    echo "=========================================="
    echo "✓ 阶段 2 完成：Orchestrator 注册完成"
    echo "=========================================="
    echo ""
else
    echo "=========================================="
    echo "❌ Orchestrator 注册失败"
    echo "=========================================="
    exit 1
fi

# 如果是仅注册模式，到此结束
if [ "$REGISTER_ONLY" == true ]; then
    echo "部署完成！（仅执行了注册）"
    exit 0
fi

# ==========================================
# 阶段 3: 部署所有 Peggo
# ==========================================
if [ "$SKIP_TO_REGISTER" == false ]; then
    if [ "$PEGGO_ONLY" == true ]; then
        echo "=========================================="
        echo "部署 Peggo Orchestrator"
        echo "=========================================="
    else
        echo "=========================================="
        echo "阶段 3/4: 部署所有 Peggo Orchestrator"
        echo "=========================================="
    fi
    echo ""
    
    if [ "$PEGGO_ONLY" == false ]; then
        echo "提示: Orchestrator 已注册，Peggo 将以 Validator 模式启动"
        echo ""
    fi

    # 仅部署 validator 节点的 Peggo（不需要 sentry）
    # VALIDATOR_HOSTS 已在前面初始化
    
    # 步骤 1: 生成并上传所有 .env 文件
    echo "步骤 1: 生成并上传 Peggo .env 文件..."
    ansible-playbook -i inventory.yml playbooks/generate-peggo-env.yml
    
    ENV_GEN_EXIT_CODE=$?
    if [ $ENV_GEN_EXIT_CODE -ne 0 ]; then
        echo "错误: .env 文件生成失败"
        exit 1
    fi
    
    echo ""
    echo "步骤 2: 配置 Peggo 服务..."
    echo ""

for host in $VALIDATOR_HOSTS; do
    HOST_IP=$(grep -A 3 "^[[:space:]]*${host}:" inventory.yml | grep "ansible_host:" | awk '{print $2}' | tr -d '"' || echo "未知")
    
    echo ""
    echo "=========================================="
    echo "准备部署 Peggo: $host"
    echo "服务器IP: ${HOST_IP}"
    echo "=========================================="
    echo ""
    
    # 构建 ansible-playbook 命令 - 仅部署 Peggo 服务（跳过 .env 生成）
    if [ "$NEED_PASSWORD" == true ]; then
        ANSIBLE_CMD="ansible-playbook -i inventory.yml playbooks/deploy-full.yml \
            --limit $host \
            --tags deploy_peggo \
            --ask-pass \
            --ask-become-pass \
            -e deploy_peggy_contract=false \
            -e deploy_peggo=true \
            -e skip_peggo_env=true"
    else
        ANSIBLE_CMD="ansible-playbook -i inventory.yml playbooks/deploy-full.yml \
            --limit $host \
            --tags deploy_peggo \
            --become \
            -e deploy_peggy_contract=false \
            -e deploy_peggo=true \
            -e skip_peggo_env=true"
    fi
    
    # 执行部署
    eval $ANSIBLE_CMD
    DEPLOY_EXIT_CODE=$?
    
    if [ $DEPLOY_EXIT_CODE -ne 0 ]; then
        echo "❌ $host Peggo 部署失败"
        exit 1
    fi
    
    echo "✓ $host Peggo 部署完成"
done
    echo ""
    
    if [ "$PEGGO_ONLY" == true ]; then
        echo "=========================================="
        echo "✓ Peggo 部署完成"
        echo "=========================================="
    else
        echo "=========================================="
        echo "✓ 阶段 3 完成：所有 Peggo 部署完成"
        echo "=========================================="
    fi
    echo ""
fi  # 结束 SKIP_TO_REGISTER == false

# 如果是仅 Peggo 模式，到此结束（不清理私钥）
if [ "$PEGGO_ONLY" == true ]; then
    echo "部署完成！（仅部署了 Peggo）"
    exit 0
fi

# ==========================================
# 阶段 4: 清理私钥文件
# ==========================================
if [ "$REGISTER_ONLY" == true ]; then
    # 这个分支永远不会执行到（上面已经 exit）
    echo "=========================================="
    echo "清理私钥文件"
    echo "=========================================="
else
    echo "=========================================="
    echo "阶段 4/4: 清理私钥文件"
    echo "=========================================="
fi

echo ""
echo "等待 Peggo 服务完成初始签名..."
sleep 10

# 清理所有节点（validator 和 sentry）的敏感文件
echo ""
echo "清理敏感密钥文件..."

for host in $HOSTS; do
    HOST_IP=$(grep -A 3 "^[[:space:]]*${host}:" inventory.yml | grep "ansible_host:" | awk '{print $2}' | tr -d '"' || echo "")
    if [ -n "$HOST_IP" ]; then
        echo "正在清理 $host ($HOST_IP)..."
        
        # 清理节点密钥文件（所有节点）
        ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no ubuntu@$HOST_IP \
            "rm -f /data/biyachain/config/node_key.json /data/biyachain/config/priv_validator_key.json" 2>/dev/null || true
        
        # 如果是 validator，还要清理 Peggo .env 文件
        if echo "$host" | grep -q "^validator-"; then
            ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no ubuntu@$HOST_IP \
                "rm -f /home/ubuntu/.peggo/.env" 2>/dev/null || true
        fi
    fi
done

echo "=========================================="
echo "✓ 私钥文件已清理"
echo "=========================================="

echo "=========================================="
echo "🎉 部署完成！"
echo "=========================================="

