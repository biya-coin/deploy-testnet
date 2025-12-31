# Peggy Bridge 跨链测试脚本

## 📁 脚本列表

- **`deploy-test-token.sh`** - 部署测试 ERC20 代币到 Sepolia
- **`transfer-eth.sh`** - 给 validator 账户转账 Sepolia ETH
- **`test-bridge.sh`** - 跨链桥功能测试（deposit/withdraw/余额查询）

---

## 📋 脚本功能分析

### `test-bridge.sh` - 跨链桥测试

交互式脚本，支持以下操作：

### 1. **deposit** - 从 Sepolia → Injective
- 将 ERC20 代币从 Sepolia 测试网跨链到 Injective 链
- 需要先在 Sepolia 上部署测试代币并授权给 Bridge 合约
- 流程：approve → sendToInjective

### 2. **withdraw** - 从 Injective → Sepolia  
- 将代币从 Injective 链跨回 Sepolia 测试网
- 需要在 Injective 上有 peggy 代币余额
- 流程：MsgSendToEthereum

### 3. **balance** - 余额查询
- 查询 Sepolia 上的 ETH 和 Token 余额
- 查询 Injective 上的代币余额

### 4. **claimINJ** - 领取 gas 费
- 从 genesis 账户向指定地址转账 inj 代币
- 用于支付 Injective 链上的交易 gas 费

## 🔧 当前配置

根据 `ansible/deploy-node.sh` 部署的环境，脚本已配置：

```bash
# Peggy 合约地址（从 peggy-contract-info.txt 读取）
BRIDGE_CONTRACT_ADDRESS="0x941Ed9AE32b1e0531e71F252A2443D8bc4f40197"

# 部署合约的私钥（从 inventory.yml 读取）
ETH_PRIVATE_KEY="0x99f65f092924fd9c7cb8125255da54ca63733be861d5cdfdb570e41182100ba1"

# Injective 节点（validator-0）
INJ_NODE="http://10.8.21.50:26757"
INJ_CHAIN_ID="biyachain-888"

# 默认 Injective 地址（validator-0 的 cosmos 地址）
DEFAULT_INJ_ADDR="inj1j84hrek0dadw663lcrkugkv8whghdyft6j6cev"
```

## ⚠️ 使用前准备

### 1. 部署测试 ERC20 代币

**使用部署脚本（推荐）**:
```bash
./deploy-test-token.sh
```

脚本会自动：
- 部署测试 ERC20 代币到 Sepolia
- 保存合约信息到 `test-token-info.txt`
- 提示如何更新 `test-bridge.sh`

**或使用已有的 Sepolia 测试代币**:
```bash
# 直接在 test-bridge.sh 中配置已有代币地址
TOKEN_ADDRESS="0x<已有测试代币地址>"
```

### 2. 确保有 Sepolia ETH

部署私钥对应的地址需要有 Sepolia ETH 用于支付 gas：

```bash
# 查看地址
cast wallet address --private-key 0x99f65f092924fd9c7cb8125255da54ca63733be861d5cdfdb570e41182100ba1

# 从水龙头获取测试 ETH
# https://sepoliafaucet.com/
# https://www.alchemy.com/faucets/ethereum-sepolia
```

### 3. 安装依赖工具

脚本会自动检查并尝试安装 Foundry（包含 `cast` 工具）：

```bash
# 手动安装 Foundry（可选）
curl -L https://foundry.paradigm.xyz | bash
foundryup

# 确保 biyachaind 可用
which biyachaind

# 安装 bc（用于数量换算）
sudo apt-get install -y bc
```

## 🚀 使用方法

### 1. 启动脚本

```bash
cd /home/ubuntu/testnet/chain-stresser/test/peggo
./test-bridge.sh
```

### 2. 首次运行

脚本会提示导入私钥到 Injective keyring：

```
接下来 biyachaind 会在前台提示设置/确认该 key 的密码
通常需要输入两次，默认建议使用 12345678
```

输入密码后，私钥会被导入为 `testKey`。

### 3. 测试流程

#### 步骤 1：查询余额（选项 3）
```
请输入选择 [1/2/3/4/5] (默认 3): 3
```
- 查看 Sepolia 上的 ETH 和 Token 余额
- 查看 Injective 上的余额

#### 步骤 2：领取 gas 费（选项 4）
```
请输入选择 [1/2/3/4/5] (默认 3): 4
```
- 从 genesis 账户获取 10 inj
- 用于支付后续 withdraw 交易的 gas 费
- 需要输入 genesis 账户密码（默认 `12345678`）

#### 步骤 3：测试 deposit（选项 1）
```
请输入选择 [1/2/3/4/5] (默认 3): 1
```
- 从 Sepolia 跨链 Token 到 Injective
- 首次使用会自动授权 Bridge 合约
- 等待 Peggo 中继交易到 Injective

#### 步骤 4：测试 withdraw（选项 2）
```
请输入选择 [1/2/3/4/5] (默认 3): 2
```
- 从 Injective 跨链 Token 回 Sepolia
- 需要输入 testKey 账户密码（默认 `12345678`）
- 等待 Peggo 中继交易到 Sepolia

## 📊 验证跨链结果

### 在 Injective 上查询

```bash
# 查询 peggy 代币余额
biyachaind q bank balances inj1j84hrek0dadw663lcrkugkv8whghdyft6j6cev \
  --node http://10.8.21.50:26757 \
  --chain-id biyachain-888

# 查询 pending batches
biyachaind q peggy pending-send-to-eth \
  --node http://10.8.21.50:26757 \
  --chain-id biyachain-888
```

### 在 Sepolia 上查询

```bash
# 查询 Token 余额
cast call <TOKEN_ADDRESS> \
  "balanceOf(address)(uint256)" \
  <YOUR_ADDRESS> \
  --rpc-url https://ethereum-sepolia.publicnode.com
```

### 查看 Peggo 日志

```bash
# 在 validator 节点上查看 Peggo 日志
ssh ubuntu@10.8.21.50
sudo journalctl -u peggo -f
```

## 🔍 故障排查

### 问题 1：Peggo 未运行

```bash
# 检查 Peggo 状态
./node-control.sh status peggo validator-0

# 如果未运行，重新部署
cd ansible
./deploy-node.sh --register-only
```

### 问题 2：签名验证失败

检查 genesis.json 中的 valset 是否包含所有 validator：

```bash
jq '.app_state.peggy.valsets[0].members | length' \
  ansible/chain-stresser-deploy/validators/0/config/genesis.json
# 应该输出 4（4 个 validator）
```

### 问题 3：余额不足

```bash
# 领取更多 inj
./test-bridge.sh
# 选择选项 4 (claimINJ)
```

### 问题 4：Token 地址未配置

修改脚本中的 `TOKEN_ADDRESS`：

```bash
vim test-bridge.sh
# 找到 TOKEN_ADDRESS 行，替换为实际地址
TOKEN_ADDRESS="0x<实际的测试代币地址>"
```

## 📝 注意事项

1. **测试环境**：此脚本仅用于测试环境，不要在生产环境使用
2. **私钥安全**：脚本中的私钥仅用于测试，不要用于存储真实资产
3. **Gas 费用**：确保有足够的 Sepolia ETH 和 inj 支付 gas 费
4. **跨链延迟**：跨链交易需要等待 Peggo 中继，可能需要几分钟
5. **Peggo 状态**：确保至少有一个 Peggo 实例在运行

## 🎯 预期结果

成功的跨链测试应该显示：

1. ✅ deposit 交易在 Sepolia 上确认
2. ✅ Peggo 检测到 deposit 事件并中继到 Injective
3. ✅ Injective 上出现 peggy 代币余额
4. ✅ withdraw 交易在 Injective 上确认
5. ✅ Peggo 创建 batch 并中继到 Sepolia
6. ✅ Sepolia 上的 Token 余额增加


