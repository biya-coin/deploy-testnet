#!/usr/bin/env python3
"""
快速应用节点配置 - 单个节点版本
"""

import yaml
import re
import sys
from pathlib import Path

def merge_config(base, override):
    result = base.copy() if base else {}
    if override:
        result.update(override)
    return result

def apply_toml(file_path, params):
    if not Path(file_path).exists():
        return
    
    with open(file_path, 'r') as f:
        content = f.read()
    
    for key, value in params.items():
        # 格式化值
        if isinstance(value, bool):
            new_value = str(value).lower()
        elif isinstance(value, (int, float)):
            new_value = str(value)
        else:
            new_value = f'"{value}"'
        
        if '.' in key:
            # 段内参数 (如 api.enable)
            section, param = key.rsplit('.', 1)
            # 匹配段标记后的参数，只匹配到行尾（不包括换行符）
            pattern = rf'(\[{re.escape(section)}\][^\[]*?)({re.escape(param)}\s*=\s*)[^\n]*'
            replacement = rf'\g<1>\g<2>{new_value}'
            content = re.sub(pattern, replacement, content, flags=re.DOTALL)
        else:
            # 简单参数 - 只匹配该行的值部分（不包括换行符）
            pattern = rf'^({re.escape(key)}\s*=\s*)[^\n]*'
            replacement = rf'\g<1>{new_value}'
            content = re.sub(pattern, replacement, content, flags=re.MULTILINE)
    
    with open(file_path, 'w') as f:
        f.write(content)

def main():
    if len(sys.argv) != 5:
        print("用法: apply_node_config_fast.py <config.yml> <node_dir> <node_name> <node_type>")
        sys.exit(1)
    
    config_file, node_dir, node_name, node_type = sys.argv[1:5]
    
    # 加载配置
    with open(config_file, 'r') as f:
        config = yaml.safe_load(f)
    
    # 合并配置
    global_cfg = config.get('global', {})
    type_cfg = config.get(node_type, {})
    specific_cfg = config.get('specific_nodes', {}).get(node_name, {})
    
    config_toml_params = merge_config(
        merge_config(global_cfg.get('config_toml', {}), type_cfg.get('config_toml', {})),
        specific_cfg.get('config_toml', {})
    )
    
    app_toml_params = merge_config(
        merge_config(global_cfg.get('app_toml', {}), type_cfg.get('app_toml', {})),
        specific_cfg.get('app_toml', {})
    )
    
    # 应用配置
    if config_toml_params:
        apply_toml(f"{node_dir}/config/config.toml", config_toml_params)
    
    if app_toml_params:
        apply_toml(f"{node_dir}/config/app.toml", app_toml_params)

if __name__ == "__main__":
    main()

