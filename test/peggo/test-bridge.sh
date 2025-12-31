#!/usr/bin/env bash
set -euo pipefail

########## 配置项（根据当前部署环境修改） ##########

# Sepolia / EVM 相关
ETH_RPC_URL="${ETH_RPC_URL:-https://ethereum-sepolia.publicnode.com}"
ETH_CHAIN_ID="${ETH_CHAIN_ID:-11155111}"
# 使用部署合约的私钥（inventory.yml 中的 peggy_deployer_from_pk）
ETH_PRIVATE_KEY="${ETH_PRIVATE_KEY:-0x99f65f092924fd9c7cb8125255da54ca63733be861d5cdfdb570e41182100ba1}"

# Peggy 桥相关（自动从 peggy-contract-info.txt 读取最新合约地址）
PEGGY_CONTRACT_INFO_FILE="../../ansible/peggy-contract-info.txt"
BRIDGE_CONTRACT_ADDRESS="0x107738aB950D6A55297B6f38A9A5bE6e631cB717"

# TODO: 需要部署一个 ERC20 测试代币，或使用已有的测试代币
TOKEN_ADDRESS="${TOKEN_ADDRESS:-0x46bcDa267c0023a9dcF6Df499edB6f07A609EE2a}"  # TestToken 合约地址
TOKEN_DECIMALS="${TOKEN_DECIMALS:-6}"

# Injective 相关（连接到部署的节点）
INJ_NODE="${INJ_NODE:-http://10.8.21.50:26757}"  # validator-0 的 RPC 地址
INJ_CHAIN_ID="${INJ_CHAIN_ID:-biyachain-888}"
INJ_KEY_NAME="${INJ_KEY_NAME:-testKey}"  # 本地 keyring 中的 key 名称
INJ_KEYRING_BACKEND="${INJ_KEYRING_BACKEND:-test}"
# 使用当前私钥对应的 Injective 地址作为默认接收地址
DEFAULT_INJ_ADDR="${DEFAULT_INJ_ADDR:-inj1xxj66daehr3qutsauu5xkvkqajknjkrztlywev}"

########## 工具函数 ##########

log() {
  local level="$1"; shift
  local msg="$*"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

ensure_tools() {
  local missing=()

  # biyachaind / jq 为硬依赖，必须已有
  for cmd in biyachaind jq; do
    if ! command_exists "$cmd"; then
      missing+=("$cmd")
    fi
  done

  if [ ${#missing[@]} -ne 0 ]; then
    log ERROR "缺少必要命令: ${missing[*]}，请先安装后再运行此脚本"
    exit 1
  fi

  # cast 可尝试自动安装（通过 foundryup）
  if ! command_exists cast; then
    log INFO "未检测到 cast，尝试自动安装 Foundry (foundryup)..."

    if ! command_exists curl; then
      log ERROR "系统未安装 curl，无法自动安装 Foundry，请手动安装 cast 或 Foundry 后重试。"
      exit 1
    fi

    # 安装 foundryup（若未安装）
    if ! command_exists foundryup; then
      curl -L https://foundry.paradigm.xyz | bash || {
        log ERROR "foundryup 安装失败，请手动安装 Foundry 后重试。"
        exit 1
      }
      # shellcheck source=/dev/null
      if [ -f "$HOME/.foundry/bin/foundryup" ]; then
        export PATH="$HOME/.foundry/bin:$PATH"
      fi
    fi

    # 运行 foundryup 安装 cast
    if command_exists foundryup; then
      foundryup || {
        log ERROR "foundryup 运行失败，请手动安装 Foundry。"
        exit 1
      }
      export PATH="$HOME/.foundry/bin:$PATH"
    fi

    if ! command_exists cast; then
      log ERROR "自动安装 Foundry 后仍未检测到 cast，请手动安装 Foundry (https://book.getfoundry.sh/) 后重试。"
      exit 1
    fi

    log INFO "已成功安装 cast。"
  fi
}

########## Injective 账户工具：为 ETH_PRIVATE_KEY 准备 Injective key ##########

ensure_injective_key_for_eth() {
  # 默认 key 名称可通过环境变量覆盖
  local key_name
  key_name="${INJ_KEY_NAME:-testKey}"

  if [ -z "${ETH_PRIVATE_KEY}" ] || [ "${ETH_PRIVATE_KEY}" = "0xYOUR_PRIVATE_KEY" ]; then
    log ERROR "ETH_PRIVATE_KEY 未配置或仍为占位值，请在环境变量或脚本中正确设置"
    return 1
  fi

  log INFO "检查 Injective keyring($INJ_KEYRING_BACKEND) 中是否已存在 key '$key_name'..."

  # 检查 key 是否已存在
  if biyachaind keys show "$key_name" --keyring-backend "$INJ_KEYRING_BACKEND" &>/dev/null; then
    log INFO "检测到已存在的 Injective key '$key_name' (keyring-backend=$INJ_KEYRING_BACKEND)，后续将使用该账户。"
    return 0
  fi

  log INFO "未在 keyring($INJ_KEYRING_BACKEND) 中检测到 '$key_name'，将使用 ETH_PRIVATE_KEY 导入为 Injective eth-key。"
  log INFO "执行: biyachaind keys unsafe-import-eth-key $key_name <privateKey> --keyring-backend $INJ_KEYRING_BACKEND"

  # 使用临时文件捕获 stderr，同时保持 stdout 可见
  TEMP_ERR=$(mktemp)
  biyachaind keys unsafe-import-eth-key "$key_name" "$ETH_PRIVATE_KEY" --keyring-backend "$INJ_KEYRING_BACKEND" 2>"$TEMP_ERR"
  IMPORT_EXIT_CODE=$?
  IMPORT_OUTPUT=$(cat "$TEMP_ERR")
  rm -f "$TEMP_ERR"
  
  # 检查是否因为 key 已存在而失败
  if [ $IMPORT_EXIT_CODE -ne 0 ] && echo "$IMPORT_OUTPUT" | grep -q "cannot overwrite key"; then
    log INFO "Key '$key_name' 已存在，将继续使用。"
    return 0
  fi
  
  # 如果是其他错误，报告并退出
  if [ $IMPORT_EXIT_CODE -ne 0 ]; then
    echo "$IMPORT_OUTPUT" >&2
    log ERROR "unsafe-import-eth-key 失败，请检查 Injective 环境和私钥配置。"
    return 1
  fi

  log INFO "已成功导入 Injective key '$key_name'，后续 withdraw/claimINJ 将复用该账户。"
}

wei_from_amount_u() {
  local amount_u="$1"    # 人类可读数量（整数，如 1、100）
  local decimals="$2"    # TOKEN_DECIMALS

  # 使用 bc 做整数运算: amount_u * 10^decimals
  if ! command_exists bc; then
    log ERROR "系统未安装 bc，无法进行数量换算，请安装后重试 (例如: sudo apt-get install -y bc)"
    exit 1
  fi

  echo "$amount_u * (10 ^ $decimals)" | bc
}

########## 地址转换工具：从 inj 推导 EVM 地址 ##########

get_evm_address_from_inj() {
  local inj_addr="$1"
  local hex

  hex="$(biyachaind debug addr "${inj_addr}" 2>/dev/null | awk '/Address \(hex\):/ {print $3}' || true)"

  if [ -z "$hex" ]; then
    log ERROR "无法从 'biyachaind debug addr' 获取 EVM hex 地址 (inj=$inj_addr)"
    return 1
  fi

  echo "0x$(echo "$hex" | tr 'A-Z' 'a-z')"
}

########## 余额查询 ##########

show_balances() {
  log INFO "查询配置私钥对应地址在 Sepolia 和 Injective 上的余额..."

  if [ -z "${ETH_PRIVATE_KEY}" ] || [ "${ETH_PRIVATE_KEY}" = "0xYOUR_PRIVATE_KEY" ]; then
    log ERROR "ETH_PRIVATE_KEY 未配置或仍为占位值，请在环境变量或脚本中正确设置"
    return 1
  fi

  # 1. 查询配置私钥对应的 EVM 地址余额（Sepolia）
  local evm_addr
  evm_addr=$(cast wallet address --private-key "$ETH_PRIVATE_KEY")
  log INFO "EVM 地址 (Sepolia): $evm_addr"

  local eth_balance
  eth_balance=$(cast balance "$evm_addr" --rpc-url "$ETH_RPC_URL")
  log INFO "Sepolia ETH 余额: $eth_balance wei"

  if [ "$TOKEN_ADDRESS" != "0xTOKEN_ADDR" ]; then
    local token_balance_hex
    token_balance_hex=$(cast call "$TOKEN_ADDRESS" "balanceOf(address)(uint256)" "$evm_addr" --rpc-url "$ETH_RPC_URL")
    log INFO "Sepolia Token 余额 (raw): $token_balance_hex"
  else
    log INFO "TOKEN_ADDRESS 仍为占位值，跳过 Token 余额查询"
  fi

  # 2. 查询默认 Injective 地址余额（如已配置 DEFAULT_INJ_ADDR）
  if [ -z "${DEFAULT_INJ_ADDR:-}" ]; then
    log INFO "DEFAULT_INJ_ADDR 未配置，跳过 Injective 余额查询。"
    return 0
  fi

  local inj_addr
  inj_addr="$DEFAULT_INJ_ADDR"
  log INFO "Injective 地址: $inj_addr"

  biyachaind q bank balances "$inj_addr" \
    --node "$INJ_NODE" \
    --chain-id "$INJ_CHAIN_ID" \
    -o text || log ERROR "查询 Injective 余额失败"
}

########## deposit：从 Sepolia → Injective ##########

deposit_to_injective() {
  ensure_tools

  if [ -z "${ETH_PRIVATE_KEY}" ] || [ "${ETH_PRIVATE_KEY}" = "0xYOUR_PRIVATE_KEY" ]; then
    log ERROR "ETH_PRIVATE_KEY 未配置或仍为占位值，请在环境变量或脚本中正确设置"
    return 1
  fi

  if [ "$BRIDGE_CONTRACT_ADDRESS" = "0xBRIDGE_ADDR" ] || [ "$TOKEN_ADDRESS" = "0xTOKEN_ADDR" ]; then
    log ERROR "BRIDGE_CONTRACT_ADDRESS 或 TOKEN_ADDRESS 仍为占位值，请正确配置"
    return 1
  fi

  # 默认接收地址为当前私钥对应的 EVM 地址
  local default_evm_addr
  default_evm_addr=$(cast wallet address --private-key "$ETH_PRIVATE_KEY")
  log INFO "默认目标 EVM 接收地址: $default_evm_addr"

  read -r -p "请输入要跨链的目标 EVM 地址 (0x...，默认: $default_evm_addr): " dest
  if [ -z "$dest" ]; then
    dest="$default_evm_addr"
  fi

  read -r -p "请输入要跨链的 Token 数量（默认 100）: " amount_u
  if [ -z "$amount_u" ]; then
    amount_u="100"
  fi

  # 统一处理目的地址为 bytes32（使用 evm 形式）
  local dest_evm
  if [[ "$dest" != 0x* ]]; then
    log ERROR "目标地址必须为 0x 开头的 EVM 地址，请重新输入"
    return 1
  fi

  dest_evm="$dest"

  # 手动将 20 字节地址左补零到 32 字节
  local dest_stripped
  dest_stripped="${dest_evm#0x}"
  if [ "${#dest_stripped}" -ne 40 ]; then
    log ERROR "目标地址长度不是 20 字节 hex: $dest_evm"
    return 1
  fi

  local dest_bytes32
  dest_bytes32="0x000000000000000000000000${dest_stripped}"

  local amount_wei
  amount_wei=$(wei_from_amount_u "$amount_u" "$TOKEN_DECIMALS")

  log INFO "使用地址: $(cast wallet address --private-key "$ETH_PRIVATE_KEY")"
  log INFO "跨链 Token 数量 (wei): $amount_wei"
  log INFO "Bridge 合约: $BRIDGE_CONTRACT_ADDRESS, Token 合约: $TOKEN_ADDRESS"

  # 1. 查询当前 allowance，如不足则授权最大值
  local owner_addr
  owner_addr="$default_evm_addr"

  log INFO "查询当前 allowance (owner=$owner_addr, spender=$BRIDGE_CONTRACT_ADDRESS)..."
  local current_allowance
  current_allowance=$(cast call "$TOKEN_ADDRESS" \
    "allowance(address,address)(uint256)" "$owner_addr" "$BRIDGE_CONTRACT_ADDRESS" \
    --rpc-url "$ETH_RPC_URL")

  log INFO "当前 allowance(raw): $current_allowance"

  # 截取空格前的纯十进制部分（cast 可能在末尾附加类似 "[1.157e77]")
  local allowance_dec
  allowance_dec="${current_allowance%% *}"

  log INFO "当前 allowance(十进制): $allowance_dec"

  # 校验格式是否为十进制整数
  if ! [[ "$allowance_dec" =~ ^[0-9]+$ ]]; then
    log ERROR "当前 allowance 非十进制整数格式: $current_allowance"
    return 1
  fi

  # 如果 allowance_dec 字符串为 "0"，则授权最大值，否则认为已足够
  if [ "$allowance_dec" = "0" ]; then
    # uint256 最大值: 2^256 - 1
    local max_uint
    max_uint="115792089237316195423570985008687907853269984665640564039457584007913129639935"
    log INFO "当前 allowance 为 0，将发送 approve 授权最大值。"
    cast send "$TOKEN_ADDRESS" \
      "approve(address,uint256)" "$BRIDGE_CONTRACT_ADDRESS" "$max_uint" \
      --rpc-url "$ETH_RPC_URL" \
      --private-key "$ETH_PRIVATE_KEY" \
      --chain "$ETH_CHAIN_ID"
  else
    log INFO "当前 allowance 已足够，本次跳过 approve。"
  fi

  # 2. sendToInjective
  log INFO "发送 sendToInjective 交易..."
  cast send "$BRIDGE_CONTRACT_ADDRESS" \
    "sendToInjective(address,bytes32,uint256,string)" \
    "$TOKEN_ADDRESS" "$dest_bytes32" "$amount_wei" "" \
    --rpc-url "$ETH_RPC_URL" \
    --private-key "$ETH_PRIVATE_KEY" \
    --chain "$ETH_CHAIN_ID"

  log INFO "deposit 交易已发送，请等待跨链桥在 Injective 上处理。"
}

########## withdraw：从 Injective → Sepolia ##########

withdraw_to_sepolia() {
  ensure_tools
  # 1. 使用已在脚本启动时确保存在的 Injective keyring 账户
  local inj_key_name
  inj_key_name="${INJ_KEY_NAME:-testKey}"

  # 2. 选择目标 EVM 地址
  local default_evm_addr
  default_evm_addr=$(cast wallet address --private-key "$ETH_PRIVATE_KEY")
  local dest_evm
  read -r -p "请输入 withdraw 的目标 EVM 地址 (0x...，默认: $default_evm_addr): " dest_evm
  if [ -z "$dest_evm" ]; then
    dest_evm="$default_evm_addr"
  fi

  if [[ "$dest_evm" != 0x* ]]; then
    log ERROR "目标 EVM 地址必须以 0x 开头，当前输入: $dest_evm"
    return 1
  fi

  # 3. 选择 withdraw 数量（Token，默认 10）
  local amount_token
  read -r -p "请输入从 Injective withdraw 到 Sepolia 的 Token 数量（默认 10枚）: " amount_token
  if [ -z "$amount_token" ]; then
    amount_token="10"
  fi

  # 将 Token 数量转换为底层单位（根据 TOKEN_DECIMALS）
  local amount_wei
  amount_wei=$(wei_from_amount_u "$amount_token" "$TOKEN_DECIMALS")

  # Peggy 代币 denom：peggy<TOKEN_ADDRESS>
  local peggy_denom
  peggy_denom="peggy${TOKEN_ADDRESS}"

  local amount_coin fee_coin
  amount_coin="${amount_wei}${peggy_denom}"

  # 手续费也使用一个相对较小的默认值（例如 1 Token），避免过大
  local fee_token
  fee_token="1"
  local fee_wei
  fee_wei=$(wei_from_amount_u "$fee_token" "$TOKEN_DECIMALS")
  fee_coin="${fee_wei}${peggy_denom}"

  log INFO "准备发送 withdraw 交易:"
  log INFO "  目标 EVM 地址: $dest_evm"
  log INFO "  withdraw 数量: $amount_token (底层单位: $amount_wei, coin: $amount_coin)"
  log INFO "  手续费金额: $fee_token (底层单位: $fee_wei, coin: $fee_coin)"
  log INFO "  使用 Injective from: $inj_key_name (keyring-backend=$INJ_KEYRING_BACKEND)"

  # 4. 发送 MsgSendToEthereum (send-to-eth)
  biyachaind tx peggy send-to-eth \
    "$dest_evm" \
    "$amount_coin" \
    "$fee_coin" \
    --from "$inj_key_name" \
    --chain-id "$INJ_CHAIN_ID" \
    --keyring-backend "$INJ_KEYRING_BACKEND" \
    --gas auto \
    --gas-adjustment 1.5 \
    --gas-prices 500000000inj \
    --node "$INJ_NODE" \
    --yes

  log INFO "withdraw 交易已广播，请在 Injective 节点和桥的对端链路上观察跨链结果。"
}

########## claimINJ：从 genesis 给指定 Injective 地址转账 inj 手续费 ##########

claim_inj() {
  ensure_tools

  # 1. 使用启动时已确保存在的 Injective eth-key（用于获取默认 inj 地址）
  local inj_key_name
  inj_key_name="${INJ_KEY_NAME:-testKey}"

  # 尝试使用启动时计算好的默认 Injective 地址，避免再次触发密码输入
  local default_inj_addr
  default_inj_addr="${DEFAULT_INJ_ADDR:-}"

  log INFO "claimINJ 将从 genesis 账户向目标 Injective 地址转账 inj，用于支付 gas。"

  local to_addr
  if [ -n "$default_inj_addr" ]; then
    read -r -p "请输入要接收 inj 的 Injective 地址 (inj...，默认: $default_inj_addr): " to_addr
    if [ -z "$to_addr" ]; then
      to_addr="$default_inj_addr"
    fi
  else
    read -r -p "请输入要接收 inj 的 Injective 地址 (inj...): " to_addr
  fi

  if [[ "$to_addr" != inj* ]]; then
    log ERROR "Injective 地址应以 inj 开头，当前输入: $to_addr"
    return 1
  fi

  # 转账数量固定为 10（人类可读单位），内部按 18 位精度换算
  local amount_display
  amount_display="10"

  # inj 使用 18 位精度，将人类可读数量转换为最小单位: amount_display * 10^18
  local inj_decimals amount_raw
  inj_decimals=18
  if ! command_exists bc; then
    log ERROR "系统未安装 bc，无法进行 inj 数量换算，请安装后重试 (例如: sudo apt-get install -y bc)"
    return 1
  fi
  amount_raw=$(echo "$amount_display * (10 ^ $inj_decimals)" | bc)

  local coin
  coin="${amount_raw}inj"

  log INFO "准备从 genesis 向 $to_addr 转账 ${amount_display}inj (底层单位: $amount_raw, coin: $coin) 作为手续费。"
  if [ "$INJ_KEYRING_BACKEND" = "file" ]; then
  log INFO "接下来 biyachaind 会在前台提示输入密码，默认是 12345678（除非你改过）。"
  fi

  # 前台运行，如果使用 file backend 需要手动输入密码
  biyachaind tx bank send genesis "$to_addr" "$coin" \
    --chain-id "$INJ_CHAIN_ID" \
    --keyring-backend "$INJ_KEYRING_BACKEND" \
    --node "$INJ_NODE" \
    --gas auto \
    --gas-adjustment 1.5 \
    --gas-prices 500000000inj \
    --yes

  log INFO "claimINJ 交易已广播，请在 Injective 节点上查看余额变更。"
}

########## 主菜单 ##########

main() {
  ensure_tools

  # 显示当前配置
  echo "==========================================  "
  echo "当前配置:"
  echo "  Peggy 合约地址: $BRIDGE_CONTRACT_ADDRESS"
  echo "  Token 地址: $TOKEN_ADDRESS"
  echo "  Injective 节点: $INJ_NODE"
  echo "  Injective 链 ID: $INJ_CHAIN_ID"
  echo "  默认 Injective 地址: $DEFAULT_INJ_ADDR"
  echo "=========================================="
  echo ""

  # 在展示菜单前，先确保 Injective keyring 中已为 ETH_PRIVATE_KEY 准备好默认账户
  ensure_injective_key_for_eth || {
    log ERROR "初始化 Injective key 失败，退出脚本。"
    exit 1
  }

  while true; do
    echo "###################### Bridge 测试脚本 ######################"
    echo "1 - deposit: 从 Sepolia 向 Injective 跨链 Token"
    echo "2 - withdraw: 从 Injective 向 Sepolia 跨链 Token"
    echo "3 - balance: 查询任意 0x/inj 地址在 Sepolia 和 Injective 上的余额"
    echo "4 - claimINJ: 从 genesis 给指定 Injective 地址转账 inj 手续费"
    echo "5 - exit: 退出脚本"
    echo "############################################################"

    read -r -p "请输入选择 [1/2/3/4/5] (默认 3): " choice

    case "$choice" in
      ""|3)
        show_balances
        ;;
      1)
        deposit_to_injective
        ;;
      2)
        withdraw_to_sepolia
        ;;
      4)
        claim_inj
        ;;
      5)
        log INFO "退出脚本。"
        break
        ;;
      *)
        log ERROR "无效选项: $choice"
        ;;
    esac

    echo
  done
}

main "$@"

