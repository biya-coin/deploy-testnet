# 添加新验证者节点指南

本目录包含用于在现有链上添加新验证者节点的脚本。

## 📋 前提条件

- 已有一个运行中的 Biyachain 测试网络
- 本地可以访问 validator-2 节点 (10.8.61.62)
- 本地已安装 biyachaind 二进制文件
- 有足够的 INJ 代币用于质押

## 🚀 完整流程

### 步骤 1: 准备新验证者节点

从本地配置复制并修改端口:

```bash
chmod +x 01-prepare-new-validator.sh
./01-prepare-new-validator.sh
```

**功能**:
- 从本地配置目录复制文件
- 修改所有端口号 (+100)
- 生成新的节点密钥
- **自动配置 persistent_peers** (连接到现有的 4 个验证者)
- 启用 PEX (Peer Exchange) 机制

**端口映射**:
| 服务 | 原端口 | 新端口 |
|------|--------|--------|
| RPC | 26757 | 26857 |
| P2P | 26756 | 26856 |
| API | 10437 | 10537 |
| gRPC | 10000 | 10100 |
| gRPC Web | 9191 | 9291 |
| JSON-RPC | 8645 | 8745 |
| JSON-RPC WS | 8646 | 8746 |
| Prometheus | 26760 | 26860 |
| Proxy App | 26758 | 26858 |
| PProf | 6160 | 6260 |

### 步骤 2: 创建验证者密钥

```bash
chmod +x 02-create-validator-key.sh
./02-create-validator-key.sh
```

**功能**:
- 创建新的验证者账户
- 生成助记词 (请妥善保存!)
- 保存地址信息到文件

**重要**: 记录下生成的地址,需要向其转账 INJ

### 步骤 3: 转账 INJ 到新账户

在任意现有验证者节点上执行:

```bash
# 获取新验证者地址
NEW_ADDR=$(cat /data/biyachain-local/validator-info.txt | grep "Validator Address" | awk '{print $3}')

# 转账 100 INJ
biyachaind tx bank send validator $NEW_ADDR 100000000000000000000inj \
  --chain-id=biyachain-888 \
  --node=http://127.0.0.1:26757 \
  --keyring-backend=test \
  --gas=auto \
  --gas-adjustment=1.5 \
  --gas-prices=500000000inj \
  --yes
```

### 步骤 4: 启动本地节点

```bash
chmod +x 03-start-local-node.sh
./03-start-local-node.sh
```

**功能**:
- 创建 systemd 服务
- 启动节点
- 等待同步

**验证**:
```bash
# 查看日志
sudo journalctl -u biyachain-local -f

# 检查状态
biyachaind status --node=http://127.0.0.1:26857
```

### 步骤 5: 提交治理提案

```bash
chmod +x 04-submit-add-validator-proposal.sh
./04-submit-add-validator-proposal.sh
```

**功能**:
- 创建治理提案
- 提交到链上
- 返回提案 ID

### 步骤 6: 投票

使用本地私钥文件对提案投票:

```bash
chmod +x 05-vote-proposal.sh
./05-vote-proposal.sh <proposal-id>
```

**示例**:
```bash
./05-vote-proposal.sh 1
```

**功能**:
- 从本地 ansible 部署目录读取验证者私钥
- 为每个验证者创建临时 keyring
- 自动签名并发送投票交易 (YES)
- 显示每个验证者的投票结果和交易哈希
- 自动清理临时 keyring

### 步骤 7: 创建验证者

等待提案通过后 (通常需要等待投票期结束):

```bash
chmod +x 06-create-validator-tx.sh
./06-create-validator-tx.sh
```

**功能**:
- 提交 create-validator 交易
- 质押 INJ 成为验证者
- 加入验证者集合

## 📊 验证结果

### 查询验证者状态

```bash
# 查询本地验证者
biyachaind query staking validator \
  $(biyachaind keys show validator --bech val -a \
    --home /data/biyachain-local \
    --keyring-backend test) \
  --node=http://127.0.0.1:26857

# 查看所有验证者
biyachaind query staking validators --node=http://127.0.0.1:26857
```

### 查询提案状态

```bash
# 查询提案
biyachaind query gov proposal <proposal-id> --node=http://127.0.0.1:26857

# 查询投票
biyachaind query gov votes <proposal-id> --node=http://127.0.0.1:26857
```

## 🔧 故障排查

### 节点无法启动

```bash
# 查看日志
sudo journalctl -u biyachain-local -n 100

# 检查端口占用
sudo netstat -tlnp | grep -E "26857|26756|1417|9190|8645"

# 重启节点
sudo systemctl restart biyachain-local
```

### 余额不足

```bash
# 查询余额
biyachaind query bank balances <address> --node=http://127.0.0.1:26857

# 从现有验证者转账
biyachaind tx bank send validator <new-address> <amount>inj \
  --chain-id=biyachain-888 \
  --node=http://127.0.0.1:26757 \
  --keyring-backend=test \
  --yes
```

### 提案被拒绝

- 检查投票结果: `biyachaind query gov votes <proposal-id>`
- 确保至少 2/3 的验证者投票
- 确保 YES 票超过 50%

## 📁 文件说明

| 文件 | 说明 |
|------|------|
| `01-prepare-new-validator.sh` | 准备新节点配置 |
| `02-create-validator-key.sh` | 创建验证者密钥 |
| `03-start-local-node.sh` | 启动本地节点 |
| `04-submit-add-validator-proposal.sh` | 提交治理提案 |
| `05-vote-proposal.sh` | 投票脚本 |
| `06-create-validator-tx.sh` | 创建验证者交易 |

## ⚠️ 注意事项

1. **备份助记词**: 步骤 2 生成的助记词必须妥善保存
2. **端口冲突**: 确保新端口未被占用
3. **同步时间**: 节点需要完全同步后才能成为验证者
4. **质押金额**: 确保有足够的 INJ 用于质押
5. **治理参数**: 提案需要满足最小质押和投票要求

## 🎯 快速开始

一键执行所有步骤 (需要手动确认):

```bash
# 准备和启动
./01-prepare-new-validator.sh && \
./02-create-validator-key.sh && \
echo "请转账 INJ 到新地址后按回车继续..." && read && \
./03-start-local-node.sh

# 等待节点同步后继续
echo "等待节点同步...按回车继续" && read && \
./04-submit-add-validator-proposal.sh

# 记录提案 ID
PROPOSAL_ID=$(cat /data/biyachain-local/proposal-id.txt)
echo "提案 ID: $PROPOSAL_ID"

# 投票
./05-vote-proposal.sh $PROPOSAL_ID

# 等待提案通过
echo "等待提案通过...按回车继续" && read && \
./06-create-validator-tx.sh
```

## 📞 支持

如有问题,请检查:
1. 节点日志: `sudo journalctl -u biyachain-local -f`
2. 链状态: `biyachaind status --node=http://127.0.0.1:26857`
3. 账户余额: `biyachaind query bank balances <address>`

