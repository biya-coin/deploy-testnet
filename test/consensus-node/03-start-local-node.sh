#!/bin/bash
# 启动本地验证者节点

set -e

NEW_NODE_HOME="/data/biyachain-local"
SERVICE_NAME="biyachain-local"

echo "=========================================="
echo "  启动本地验证者节点"
echo "=========================================="
echo ""

# 检查节点目录
if [ ! -d "$NEW_NODE_HOME" ]; then
    echo "❌ 错误: 节点目录不存在: $NEW_NODE_HOME"
    echo "请先运行 01-prepare-new-validator.sh"
    exit 1
fi

# 创建 systemd 服务文件
echo "创建 systemd 服务..."

sudo tee /etc/systemd/system/$SERVICE_NAME.service > /dev/null <<EOF
[Unit]
Description=Biyachain Local Validator Node
After=network-online.target

[Service]
User=$USER
ExecStart=/usr/local/biyachain/bin/biyachaind start --home=$NEW_NODE_HOME
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
Environment="LD_LIBRARY_PATH=/usr/local/biyachain/lib"

[Install]
WantedBy=multi-user.target
EOF

echo "✓ 服务文件已创建"

# 重载 systemd
sudo systemctl daemon-reload

# 启动服务
echo "启动节点服务..."
sudo systemctl enable $SERVICE_NAME
sudo systemctl start $SERVICE_NAME

# 等待启动
echo "等待节点启动..."
sleep 3

# 检查状态
echo ""
echo "=========================================="
echo "  节点状态"
echo "=========================================="

sudo systemctl status $SERVICE_NAME --no-pager -l || true

echo ""
echo "=========================================="
echo "  节点信息"
echo "=========================================="

# 等待 RPC 就绪
MAX_WAIT=30
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if /usr/local/biyachain/bin/biyachaind status --node=http://127.0.0.1:26857 2>/dev/null | grep -q "height"; then
        break
    fi
    WAIT_COUNT=$((WAIT_COUNT + 1))
    echo "等待 RPC 就绪... ($WAIT_COUNT/$MAX_WAIT)"
    sleep 1
done

# 显示状态
/usr/local/biyachain/bin/biyachaind status --node=http://127.0.0.1:26857 2>/dev/null | jq '.' || echo "RPC 未就绪"

echo ""
echo "✓ 节点已启动"
echo ""
echo "端口信息:"
echo "  RPC:       http://127.0.0.1:26857"
echo "  P2P:       tcp://127.0.0.1:26856"
echo "  API:       http://127.0.0.1:10537"
echo "  gRPC:      127.0.0.1:10100"
echo "  gRPC Web:  127.0.0.1:9291"
echo "  JSON-RPC:  http://127.0.0.1:8745"
echo "  JSON-RPC WS: ws://127.0.0.1:8746"
echo "  Prometheus: http://127.0.0.1:26860"
echo ""
echo "查看日志:"
echo "  sudo journalctl -u $SERVICE_NAME -f"
echo ""
echo "下一步:"
echo "  1. 确保节点同步到最新高度"
echo "  2. 确保验证者账户有足够的 INJ"
echo "  3. 运行 04-submit-add-validator-proposal.sh 提交治理提案"
echo ""

