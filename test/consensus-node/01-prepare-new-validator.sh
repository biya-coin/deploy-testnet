#!/bin/bash
# 准备新验证者节点 - 从本地配置复制并修改端口

set -e

# 配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_CONFIG_DIR="$SCRIPT_DIR/../ansible/chain-stresser-deploy/validators/2/config"
NEW_NODE_NAME="validator-local"
NEW_NODE_HOME="/data/biyachain-local"
PORT_OFFSET=100  # 所有端口号增加 100

echo "=========================================="
echo "  准备新验证者节点"
echo "=========================================="
echo ""
echo "源配置目录: $SOURCE_CONFIG_DIR"
echo "新节点: $NEW_NODE_NAME"
echo "新节点目录: $NEW_NODE_HOME"
echo "端口偏移: +$PORT_OFFSET"
echo ""

# 检查源配置目录是否存在
if [ ! -d "$SOURCE_CONFIG_DIR" ]; then
    echo "❌ 错误: 源配置目录不存在: $SOURCE_CONFIG_DIR"
    exit 1
fi

# 检查是否已存在
if [ -d "$NEW_NODE_HOME" ]; then
    echo "⚠️  警告: 目录 $NEW_NODE_HOME 已存在"
    read -p "是否删除并重新创建? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        sudo rm -rf "$NEW_NODE_HOME"
        echo "✓ 已删除旧目录"
    else
        echo "已取消"
        exit 1
    fi
fi

# 创建新目录
echo "创建新节点目录..."
sudo mkdir -p "$NEW_NODE_HOME/config"
sudo chown -R $USER:$USER "$NEW_NODE_HOME"

# 从本地复制配置文件
echo "从本地配置目录复制文件..."
cp -r "$SOURCE_CONFIG_DIR"/* "$NEW_NODE_HOME/config/" || {
    echo "❌ 错误: 无法复制配置文件"
    exit 1
}

echo "✓ 配置文件已复制"

# 配置 persistent_peers (连接到现有的验证者节点)
echo ""
echo "配置 P2P 连接..."

# 获取 validator-2 的 Node ID (同机器,使用本地连接)
VALIDATOR_2_RPC="http://127.0.0.1:26757"
echo "  获取 validator-2 的 Node ID..."
VALIDATOR_2_NODE_ID=$(curl -s "$VALIDATOR_2_RPC/status" 2>/dev/null | jq -r '.result.node_info.id' 2>/dev/null || echo "")

if [ -z "$VALIDATOR_2_NODE_ID" ]; then
    echo "  ⚠️  警告: 无法从 validator-2 获取 Node ID,使用默认值"
    VALIDATOR_2_NODE_ID="bfb192704ecd93e155ee79a3c79e75d09a9bda22"
fi

# 新节点与 validator-2 在同一台机器上
# 由于网络隔离,新节点只能通过 validator-2 连接到网络
# 这是正常的,validator-2 会作为中继节点
PERSISTENT_PEERS="${VALIDATOR_2_NODE_ID}@127.0.0.1:26756"

echo "  ✓ 配置连接到 validator-2 (本机)"
echo "  Persistent Peer: ${PERSISTENT_PEERS}"
echo ""
echo "  说明:"
echo "    - 新节点与 validator-2 在同一台机器上"
echo "    - validator-2 作为中继节点连接到其他验证者"
echo "    - 通过 PEX 机制,新节点会自动发现网络中的其他节点"
echo "    - 这是内网节点的标准配置方式"

# 修改端口配置
echo ""
echo "修改端口配置..."
echo "原端口 -> 新端口 (偏移 +$PORT_OFFSET)"

# config.toml 端口修改
CONFIG_FILE="$NEW_NODE_HOME/config/config.toml"

if [ -f "$CONFIG_FILE" ]; then
    echo "  修改 config.toml..."
    
    # RPC 端口: 26757 -> 26857
    echo "    RPC: 26757 -> 26857"
    sed -i 's/laddr = "tcp:\/\/0\.0\.0\.0:26757"/laddr = "tcp:\/\/0.0.0.0:26857"/' "$CONFIG_FILE"
    sed -i 's/laddr = "tcp:\/\/127\.0\.0\.1:26757"/laddr = "tcp:\/\/127.0.0.1:26857"/' "$CONFIG_FILE"
    
    # P2P 端口: 26756 -> 26856
    echo "    P2P: 26756 -> 26856"
    sed -i 's/laddr = "tcp:\/\/0\.0\.0\.0:26756"/laddr = "tcp:\/\/0.0.0.0:26856"/' "$CONFIG_FILE"
    
    # Prometheus 端口: 26760 -> 26860
    echo "    Prometheus: 26760 -> 26860"
    sed -i 's/prometheus_listen_addr = ":26760"/prometheus_listen_addr = ":26860"/' "$CONFIG_FILE"
    
    # Proxy App 端口: 26758 -> 26858
    echo "    Proxy App: 26758 -> 26858"
    sed -i 's/proxy_app = "tcp:\/\/127\.0\.0\.1:26758"/proxy_app = "tcp:\/\/127.0.0.1:26858"/' "$CONFIG_FILE"
    
    # 配置 persistent_peers
    echo ""
    echo "  配置 persistent_peers..."
    sed -i "s/^persistent_peers = .*/persistent_peers = \"$PERSISTENT_PEERS\"/" "$CONFIG_FILE"
    
    # 启用 PEX (Peer Exchange) - 确保能发现其他节点
    sed -i 's/^pex = .*/pex = true/' "$CONFIG_FILE"
    
    # 允许外部连接 (如果需要其他节点主动连接)
    sed -i 's/^addr_book_strict = .*/addr_book_strict = false/' "$CONFIG_FILE"
    
    echo "  ✓ config.toml 端口已修改"
    echo "  ✓ P2P 配置已更新"
else
    echo "  ⚠️  未找到 config.toml"
fi

# app.toml 端口修改
APP_FILE="$NEW_NODE_HOME/config/app.toml"

if [ -f "$APP_FILE" ]; then
    echo "  修改 app.toml..."
    
    # API 端口: 10437 -> 10537
    echo "    API: 10437 -> 10537"
    sed -i 's/address = "tcp:\/\/0\.0\.0\.0:10437"/address = "tcp:\/\/0.0.0.0:10537"/' "$APP_FILE"
    sed -i 's/address = "tcp:\/\/localhost:10437"/address = "tcp:\/\/localhost:10537"/' "$APP_FILE"
    
    # gRPC 端口: 10000 -> 10100
    echo "    gRPC: 10000 -> 10100"
    sed -i 's/address = "0\.0\.0\.0:10000"/address = "0.0.0.0:10100"/' "$APP_FILE"
    sed -i 's/address = "localhost:10000"/address = "localhost:10100"/' "$APP_FILE"
    
    # gRPC Web 端口: 9191 -> 9291
    echo "    gRPC Web: 9191 -> 9291"
    sed -i 's/address = "0\.0\.0\.0:9191"/address = "0.0.0.0:9291"/' "$APP_FILE"
    
    # JSON-RPC 端口: 8645 -> 8745
    echo "    JSON-RPC: 8645 -> 8745"
    sed -i 's/address = "0\.0\.0\.0:8645"/address = "0.0.0.0:8745"/' "$APP_FILE"
    
    # JSON-RPC WS 端口: 8646 -> 8746
    echo "    JSON-RPC WS: 8646 -> 8746"
    sed -i 's/ws-address = "0\.0\.0\.0:8646"/ws-address = "0.0.0.0:8746"/' "$APP_FILE"
    
    # PProf 端口: 6160 -> 6260
    echo "    PProf: 6160 -> 6260"
    sed -i 's/profiler_laddr = "localhost:6160"/profiler_laddr = "localhost:6260"/' "$APP_FILE"
    
    echo "  ✓ app.toml 端口已修改"
else
    echo "  ⚠️  未找到 app.toml"
fi

# 生成新的节点密钥
echo ""
echo "生成新的节点密钥..."

# 备份原有密钥
if [ -f "$NEW_NODE_HOME/config/node_key.json" ]; then
    mv "$NEW_NODE_HOME/config/node_key.json" "$NEW_NODE_HOME/config/node_key.json.bak"
fi

if [ -f "$NEW_NODE_HOME/config/priv_validator_key.json" ]; then
    mv "$NEW_NODE_HOME/config/priv_validator_key.json" "$NEW_NODE_HOME/config/priv_validator_key.json.bak"
fi

# 备份 genesis.json
if [ -f "$NEW_NODE_HOME/config/genesis.json" ]; then
    cp "$NEW_NODE_HOME/config/genesis.json" "$NEW_NODE_HOME/config/genesis.json.bak"
fi

# 初始化新节点 (仅生成密钥，不覆盖 genesis)
/usr/local/biyachain/bin/biyachaind init "$NEW_NODE_NAME" --home "$NEW_NODE_HOME" --chain-id biyachain-888 2>/dev/null || true

# 恢复 genesis.json (使用源配置的)
if [ -f "$NEW_NODE_HOME/config/genesis.json.bak" ]; then
    mv "$NEW_NODE_HOME/config/genesis.json.bak" "$NEW_NODE_HOME/config/genesis.json"
    echo "  ✓ 已恢复原始 genesis.json"
fi

echo "✓ 新节点密钥已生成"

# 获取新节点信息
echo ""
echo "=========================================="
echo "  新节点信息"
echo "=========================================="

NODE_ID=$(/usr/local/biyachain/bin/biyachaind tendermint show-node-id --home "$NEW_NODE_HOME")
VALIDATOR_KEY=$(/usr/local/biyachain/bin/biyachaind tendermint show-validator --home "$NEW_NODE_HOME")
VALIDATOR_ADDR=$(/usr/local/biyachain/bin/biyachaind keys show validator --bech val --home "$NEW_NODE_HOME" 2>/dev/null || echo "需要创建验证者密钥")

echo "Node ID: $NODE_ID"
echo "Validator Key: $VALIDATOR_KEY"
echo ""
echo "新节点配置完成!"
echo ""
echo "下一步:"
echo "  1. 运行 02-create-validator-key.sh 创建验证者密钥"
echo "  2. 运行 03-start-local-node.sh 启动本地节点"
echo "  3. 运行 04-submit-add-validator-proposal.sh 提交治理提案"
echo ""

