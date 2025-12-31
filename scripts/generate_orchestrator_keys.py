#!/usr/bin/env python3
"""
为所有 Validator 生成 Orchestrator 密钥信息
- Cosmos 地址（从已生成的 keyring 读取）
- EVM 地址（从私钥推导）
- 共享私钥（secp256k1，同时兼容 Cosmos 和以太坊）
"""

import json
import sys
import subprocess
from pathlib import Path
from typing import Dict, Optional
from eth_account import Account


def run_command(cmd: list, input_text: str = None) -> tuple:
    """执行命令并返回输出"""
    try:
        result = subprocess.run(
            cmd,
            input=input_text if input_text else None,
            capture_output=True,
            text=True,
            check=False
        )
        return result.returncode, result.stdout.strip(), result.stderr.strip()
    except Exception as e:
        return 1, "", str(e)


def derive_evm_address(private_key: str) -> Optional[str]:
    """从私钥推导以太坊地址"""
    try:
        # 确保私钥格式正确
        if private_key.startswith('0x'):
            private_key = private_key[2:]
        
        if len(private_key) != 64:
            return None
        
        # 使用 eth_account 推导地址
        account = Account.from_key(bytes.fromhex(private_key))
        # 返回不带 0x 前缀的小写地址
        return account.address.lower().replace('0x', '')
    except Exception as e:
        print(f"推导 EVM 地址失败: {e}", file=sys.stderr)
        return None


def get_orchestrator_key_info(
    validator_name: str,
    chain_binary: str,
    master_home: str,
    keyring_backend: str = "test"
) -> Optional[Dict]:
    """获取已生成的 orchestrator 密钥信息"""
    
    key_name = f"orchestrator-{validator_name}"
    
    # 1. 获取 Cosmos 地址
    cmd = [
        chain_binary, 'keys', 'show', key_name, '-a',
        '--home', master_home,
        '--keyring-backend', keyring_backend
    ]
    
    # test 模式不需要密码
    rc, cosmos_addr, stderr = run_command(cmd, input_text=None)
    
    if rc != 0 or not cosmos_addr:
        print(f"✗ 获取 Cosmos 地址失败: {key_name}", file=sys.stderr)
        if stderr:
            print(f"   错误: {stderr}", file=sys.stderr)
        return None
    
    # 2. 导出私钥
    cmd = [
        chain_binary, 'keys', 'unsafe-export-eth-key', key_name,
        '--home', master_home,
        '--keyring-backend', keyring_backend
    ]
    
    # test 模式不需要密码
    rc, private_key, stderr = run_command(cmd, input_text=None)
    
    if rc != 0 or not private_key:
        print(f"✗ 导出私钥失败: {key_name}", file=sys.stderr)
        if stderr:
            print(f"   错误: {stderr}", file=sys.stderr)
        return None
    
    # 移除可能的 0x 前缀
    if private_key.startswith('0x'):
        private_key = private_key[2:]
    
    # 3. 推导 EVM 地址
    evm_addr = derive_evm_address(private_key)
    
    if not evm_addr:
        print(f"✗ 推导 EVM 地址失败: {key_name}", file=sys.stderr)
        return None
    
    return {
        "validator_name": validator_name,
        "cosmos_address": cosmos_addr,
        "cosmos_private_key": private_key,
        "evm_address": evm_addr,
        "evm_private_key": private_key,
        "note": "Cosmos 和 EVM 使用相同的私钥（secp256k1），只是地址编码格式不同"
    }


def main():
    if len(sys.argv) < 6 or len(sys.argv) > 7:
        print("用法: generate_orchestrator_keys.py <chain_binary> <master_home> <output_dir> <keyring_backend> <validator_names_json> [output_filename]")
        print("示例: generate_orchestrator_keys.py biyachaind /path/to/master /path/to/output 'test' '[\"validator-0\",\"validator-1\"]'")
        print("      generate_orchestrator_keys.py biyachaind /path/to/master /path/to/output 'test' '[\"validator-0\"]' 'peggo_evm_key.json'")
        sys.exit(1)
    
    chain_binary = sys.argv[1]
    master_home = sys.argv[2]
    output_dir = sys.argv[3]
    keyring_backend = sys.argv[4]  # "test" 或 "file"
    validator_names_str = sys.argv[5]
    output_filename = sys.argv[6] if len(sys.argv) == 7 else None  # 可选的自定义文件名
    
    try:
        validator_names = json.loads(validator_names_str)
    except json.JSONDecodeError as e:
        print(f"错误: 无法解析 validator 名称 JSON: {e}", file=sys.stderr)
        sys.exit(1)
    
    if not isinstance(validator_names, list):
        print("错误: validator_names 必须是数组", file=sys.stderr)
        sys.exit(1)
    
    # 确保输出目录存在
    output_path = Path(output_dir)
    output_path.mkdir(parents=True, exist_ok=True)
    
    print("导出 Orchestrator 密钥信息...")
    
    success_count = 0
    failed_validators = []
    
    for validator_name in sorted(validator_names):
        key_info = get_orchestrator_key_info(
            validator_name,
            chain_binary,
            master_home,
            keyring_backend
        )
        
        if key_info:
            # 根据是否提供自定义文件名，决定输出文件路径
            if output_filename:
                # 使用自定义文件名（不带 validator 名称前缀）
                output_file = output_path / output_filename
            else:
                # 使用默认文件名格式
                output_file = output_path / f"{validator_name}_orchestrator_key.json"
            
            with open(output_file, 'w', encoding='utf-8') as f:
                json.dump(key_info, f, indent=2, ensure_ascii=False)
            
            # 设置文件权限为 600（仅所有者可读写）
            output_file.chmod(0o600)
            
            success_count += 1
            print(f"  ✓ {validator_name}: {key_info['cosmos_address']} (EVM: 0x{key_info['evm_address']})")
        else:
            failed_validators.append(validator_name)
            print(f"  ✗ {validator_name}: 导出失败", file=sys.stderr)
    
    print(f"\n✓ 成功导出 {success_count}/{len(validator_names)} 个 Orchestrator 密钥")
    
    if failed_validators:
        print(f"✗ 失败的 validators: {', '.join(failed_validators)}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
