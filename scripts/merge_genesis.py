#!/usr/bin/env python3
"""
Genesis.json 智能合并工具
自动将 genesis_config.yml 的配置递归合并到 genesis.json
"""

import json
import yaml
import sys
from pathlib import Path
from typing import Any, Dict


def deep_merge(base: Dict, updates: Dict) -> Dict:
    """
    深度合并两个字典
    updates 中的值会覆盖 base 中的值
    """
    result = base.copy()
    
    for key, value in updates.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            # 递归合并嵌套字典
            result[key] = deep_merge(result[key], value)
        else:
            # 直接覆盖值
            result[key] = value
    
    return result


def load_yaml(file_path: str) -> Dict:
    """加载 YAML 文件"""
    with open(file_path, 'r', encoding='utf-8') as f:
        return yaml.safe_load(f) or {}


def load_json(file_path: str) -> Dict:
    """加载 JSON 文件"""
    with open(file_path, 'r', encoding='utf-8') as f:
        return json.load(f)


def save_json(file_path: str, data: Dict):
    """保存 JSON 文件（格式化）"""
    with open(file_path, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


def main():
    if len(sys.argv) != 3:
        print("用法: merge_genesis.py <genesis_config.yml> <genesis.json>")
        sys.exit(1)
    
    config_file = sys.argv[1]
    genesis_file = sys.argv[2]
    
    # 检查文件是否存在
    if not Path(config_file).exists():
        print(f"错误: 配置文件不存在: {config_file}")
        sys.exit(1)
    
    if not Path(genesis_file).exists():
        print(f"错误: Genesis 文件不存在: {genesis_file}")
        sys.exit(1)
    
    try:
        # 加载配置和 genesis
        print(f"加载配置: {config_file}")
        config = load_yaml(config_file)
        
        print(f"加载 Genesis: {genesis_file}")
        genesis = load_json(genesis_file)
        
        # 深度合并
        print("合并配置到 Genesis...")
        merged = deep_merge(genesis, config)
        
        # 保存结果
        print(f"保存 Genesis: {genesis_file}")
        save_json(genesis_file, merged)
        
        print("✓ Genesis 配置合并完成")
        
        # 显示修改的字段
        print("\n已应用的配置:")
        print_changes(config, prefix="  ")
        
    except Exception as e:
        print(f"错误: {e}")
        sys.exit(1)


def print_changes(data: Any, prefix: str = "", max_depth: int = 3, current_depth: int = 0):
    """打印配置变更（限制深度避免输出过多）"""
    if current_depth >= max_depth:
        return
    
    if isinstance(data, dict):
        for key, value in data.items():
            if isinstance(value, dict):
                print(f"{prefix}{key}:")
                print_changes(value, prefix + "  ", max_depth, current_depth + 1)
            elif isinstance(value, list) and len(value) > 0 and isinstance(value[0], dict):
                print(f"{prefix}{key}: [{len(value)} items]")
            else:
                print(f"{prefix}{key}: {value}")


if __name__ == "__main__":
    main()

