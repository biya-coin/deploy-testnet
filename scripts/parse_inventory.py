#!/usr/bin/env python3
"""
解析 Ansible inventory.yml 文件
提取 validator 和 sentry 节点信息
"""

import yaml
import sys
from pathlib import Path


def parse_inventory(inventory_file: str, output_format: str = "bash") -> None:
    """
    解析 inventory.yml 文件
    
    Args:
        inventory_file: inventory.yml 文件路径
        output_format: 输出格式 (bash|json|yaml)
    """
    if not Path(inventory_file).exists():
        print(f"错误: inventory 文件不存在: {inventory_file}", file=sys.stderr)
        sys.exit(1)
    
    try:
        with open(inventory_file, 'r', encoding='utf-8') as f:
            inv = yaml.safe_load(f)
    except Exception as e:
        print(f"错误: 无法解析 inventory 文件: {e}", file=sys.stderr)
        sys.exit(1)
    
    hosts = inv.get('all', {}).get('hosts', {})
    
    validators = {}
    sentries = {}
    
    for name, config in sorted(hosts.items()):
        if name.startswith('validator-'):
            ip = config.get('ansible_host', '')
            if ip:
                validators[name] = ip
        elif name.startswith('sentry-'):
            ip = config.get('ansible_host', '')
            if ip:
                sentries[name] = ip
    
    if output_format == "bash":
        # Bash 可解析的格式：TYPE:NAME:IP
        for name, ip in validators.items():
            print(f"VALIDATOR:{name}:{ip}")
        for name, ip in sentries.items():
            print(f"SENTRY:{name}:{ip}")
    
    elif output_format == "json":
        import json
        result = {
            "validators": validators,
            "sentries": sentries
        }
        print(json.dumps(result, indent=2))
    
    elif output_format == "yaml":
        result = {
            "validators": validators,
            "sentries": sentries
        }
        print(yaml.dump(result, default_flow_style=False))
    
    else:
        print(f"错误: 不支持的输出格式: {output_format}", file=sys.stderr)
        sys.exit(1)


def main():
    if len(sys.argv) < 2:
        print("用法: parse_inventory.py <inventory.yml> [output_format]")
        print("")
        print("参数:")
        print("  inventory.yml   - Ansible inventory 文件路径")
        print("  output_format   - 输出格式: bash|json|yaml (默认: bash)")
        print("")
        print("示例:")
        print("  parse_inventory.py ansible/inventory.yml")
        print("  parse_inventory.py ansible/inventory.yml json")
        sys.exit(1)
    
    inventory_file = sys.argv[1]
    output_format = sys.argv[2] if len(sys.argv) > 2 else "bash"
    
    parse_inventory(inventory_file, output_format)


if __name__ == "__main__":
    main()

