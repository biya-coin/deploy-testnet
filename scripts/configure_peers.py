#!/usr/bin/env python3
"""
配置节点的 persistent_peers
根据节点类型自动配置 P2P 连接
"""

import yaml
import re
import sys
import subprocess
from pathlib import Path
from typing import Dict, List


def load_yaml(file_path: str) -> dict:
    """加载 YAML 文件"""
    with open(file_path, 'r', encoding='utf-8') as f:
        return yaml.safe_load(f) or {}


def get_p2p_port(node_config_file: str) -> str:
    """从 node_config.yml 读取 P2P 端口"""
    try:
        config = load_yaml(node_config_file)
        p2p_laddr = config.get('global', {}).get('config_toml', {}).get('p2p.laddr', 'tcp://0.0.0.0:26656')
        
        # 提取端口号（格式：tcp://0.0.0.0:26656）
        if ':' in p2p_laddr:
            port = p2p_laddr.split(':')[-1]
            return port
        else:
            return '26656'
    except Exception as e:
        print(f"警告: 无法读取 P2P 端口，使用默认值 26656: {e}", file=sys.stderr)
        return '26656'


def get_node_id(chain_binary: str, node_home: str) -> str:
    """获取节点的 node_id"""
    try:
        result = subprocess.run(
            [chain_binary, 'tendermint', 'show-node-id', '--home', node_home],
            capture_output=True,
            text=True,
            check=True
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError:
        return ""


def collect_node_ids(chain_binary: str, base_dir: str, nodes: Dict[str, str]) -> Dict[str, str]:
    """收集所有节点的 node_id"""
    node_ids = {}
    for name in sorted(nodes.keys()):
        node_home = f"{base_dir}/{name}"
        node_id = get_node_id(chain_binary, node_home)
        if node_id:
            node_ids[name] = node_id
    return node_ids


def build_peers(node_ids: Dict[str, str], nodes: Dict[str, str], exclude: str, p2p_port: str) -> str:
    """构建 persistent_peers 字符串"""
    peers = []
    for name in sorted(nodes.keys()):
        if name != exclude:
            node_id = node_ids.get(name)
            node_ip = nodes.get(name)
            if node_id and node_ip:
                peers.append(f"{node_id}@{node_ip}:{p2p_port}")
    return ','.join(peers)


def update_config_toml(config_file: str, peers: str):
    """更新 config.toml 中的 persistent_peers"""
    if not Path(config_file).exists():
        print(f"警告: 配置文件不存在: {config_file}", file=sys.stderr)
        return False
    
    with open(config_file, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # 使用正则表达式替换 persistent_peers
    pattern = r'^persistent_peers = .*'
    replacement = f'persistent_peers = "{peers}"'
    
    new_content = re.sub(pattern, replacement, content, flags=re.MULTILINE)
    
    with open(config_file, 'w', encoding='utf-8') as f:
        f.write(new_content)
    
    return True


def configure_persistent_peers(
    chain_binary: str,
    base_dir: str,
    node_config_file: str,
    inventory_file: str
):
    """配置所有节点的 persistent_peers"""
    
    # 1. 读取 P2P 端口
    p2p_port = get_p2p_port(node_config_file)
    print(f"使用 P2P 端口: {p2p_port}")
    
    # 2. 从 inventory.yml 读取节点列表
    inventory = load_yaml(inventory_file)
    hosts = inventory.get('all', {}).get('hosts', {})
    
    validators = {}
    sentries = {}
    
    for name, config in hosts.items():
        ip = config.get('ansible_host', '')
        if name.startswith('validator-') and ip:
            validators[name] = ip
        elif name.startswith('sentry-') and ip:
            sentries[name] = ip
    
    if not validators:
        print("错误: 未找到任何 validator 节点", file=sys.stderr)
        sys.exit(1)
    
    print(f"找到 {len(validators)} 个 validator, {len(sentries)} 个 sentry 节点")
    
    # 3. 收集所有节点的 node_id
    all_nodes = {**validators, **sentries}
    node_ids = collect_node_ids(chain_binary, base_dir, all_nodes)
    
    if not node_ids:
        print("错误: 无法获取任何节点的 node_id", file=sys.stderr)
        sys.exit(1)
    
    # 4. 配置 validator 节点：连接到其他所有 validator
    print("\n配置 Validator 节点:")
    for name in sorted(validators.keys()):
        peers = build_peers(node_ids, validators, name, p2p_port)
        config_file = f"{base_dir}/{name}/config/config.toml"
        
        if update_config_toml(config_file, peers):
            print(f"  ✓ {name} -> {peers if peers else '无'}")
        else:
            print(f"  ✗ {name} 配置失败", file=sys.stderr)
    
    # 5. 配置 sentry 节点：只连接所有 validator
    if sentries:
        print("\n配置 Sentry 节点:")
        for name in sorted(sentries.keys()):
            peers = build_peers(node_ids, validators, "", p2p_port)  # 不排除任何节点
            config_file = f"{base_dir}/{name}/config/config.toml"
            
            if update_config_toml(config_file, peers):
                print(f"  ✓ {name} -> {peers if peers else '无'}")
            else:
                print(f"  ✗ {name} 配置失败", file=sys.stderr)
    
    print("\n✓ P2P 连接配置完成")


def main():
    if len(sys.argv) != 5:
        print("用法: configure_peers.py <chain_binary> <base_dir> <node_config.yml> <inventory.yml>")
        print("示例: configure_peers.py injectived ./chain-deploy-config node_config.yml ansible/inventory.yml")
        sys.exit(1)
    
    chain_binary = sys.argv[1]
    base_dir = sys.argv[2]
    node_config_file = sys.argv[3]
    inventory_file = sys.argv[4]
    
    # 检查文件是否存在
    if not Path(node_config_file).exists():
        print(f"错误: 配置文件不存在: {node_config_file}", file=sys.stderr)
        sys.exit(1)
    
    if not Path(inventory_file).exists():
        print(f"错误: Inventory 文件不存在: {inventory_file}", file=sys.stderr)
        sys.exit(1)
    
    if not Path(base_dir).exists():
        print(f"错误: 基础目录不存在: {base_dir}", file=sys.stderr)
        sys.exit(1)
    
    try:
        configure_persistent_peers(chain_binary, base_dir, node_config_file, inventory_file)
    except Exception as e:
        print(f"错误: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()

