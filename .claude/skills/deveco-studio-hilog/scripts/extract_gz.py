#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
解压指定目录中的所有 .gz 文件（跨平台兼容）

使用方法:
    python extract_gz.py <目录路径>

支持 Windows/macOS/Linux
"""
import gzip
import shutil
import os
import sys
import json
from pathlib import Path

# 设置控制台输出编码为 UTF-8（Windows）
if sys.platform == 'win32':
    import io
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8')

def decompress_gz_files(source_dir):
    """
    解压指定目录下的所有 .gz 文件

    Args:
        source_dir: 包含 .gz 文件的目录路径

    Returns:
        dict: 包含解压结果的字典
    """
    result = {
        'success': False,
        'directory': str(source_dir),
        'total_files': 0,
        'success_count': 0,
        'fail_count': 0,
        'files': []
    }

    source_path = Path(source_dir)

    if not source_path.exists():
        result['error'] = f'目录不存在: {source_dir}'
        result['message'] = f'错误: {result["error"]}'
        return result

    if not source_path.is_dir():
        result['error'] = f'不是目录: {source_dir}'
        result['message'] = f'错误: {result["error"]}'
        return result

    gz_files = list(source_path.glob("*.gz"))

    if not gz_files:
        result['message'] = f'未找到 .gz 文件在: {source_dir}'
        result['success'] = True  # 不是错误，只是没有文件
        return result

    result['total_files'] = len(gz_files)

    for gz_file in gz_files:
        # 生成输出文件名（去掉 .gz 后缀）
        output_file = gz_file.with_suffix('')

        file_result = {
            'gz_file': gz_file.name,
            'output_file': output_file.name,
            'success': False,
            'error': None,
            'original_size': 0,
            'output_size': 0
        }

        try:
            original_size = gz_file.stat().st_size

            # 打开压缩文件并写入解压内容
            with gzip.open(gz_file, 'rb') as f_in:
                with open(output_file, 'wb') as f_out:
                    shutil.copyfileobj(f_in, f_out)

            output_size = output_file.stat().st_size

            file_result['success'] = True
            file_result['original_size'] = original_size
            file_result['output_size'] = output_size
            result['success_count'] += 1

        except Exception as e:
            file_result['error'] = str(e)
            result['fail_count'] += 1

        result['files'].append(file_result)

    result['success'] = True
    result['message'] = f'完成: 成功 {result["success_count"]} 个, 失败 {result["fail_count"]} 个'

    return result

def main():
    if len(sys.argv) < 2:
        print('用法: extract_gz.py <目录路径>')
        print('示例:')
        print('  Windows:  python extract_gz.py D:\\logs\\emulator_log_extracted\\SystemLog')
        print('  macOS/Linux:  python3 extract_gz.py /tmp/emulator_log_extracted/SystemLog')
        sys.exit(1)

    directory = sys.argv[1]

    print('=' * 60)
    print('开始解压 .gz 文件')
    print('=' * 60)
    print(f'目标目录: {directory}')
    print()

    result = decompress_gz_files(directory)

    if result['success']:
        print(f"找到 {result['total_files']} 个 .gz 文件")
        print('-' * 60)

        for file_info in result['files']:
            print(f"解压: {file_info['gz_file']}")
            if file_info['success']:
                print(f"  ✓ 成功 -> {file_info['output_file']}")
                print(f"  压缩大小: {file_info['original_size']:,} 字节")
                print(f"  解压后大小: {file_info['output_size']:,} 字节")
            else:
                print(f"  ✗ 失败: {file_info['error']}")
            print()

        print('-' * 60)
        print(result['message'])
    else:
        print(f"错误: {result.get('error', '未知错误')}")

    # 输出 JSON 格式的结果（用于脚本调用）
    if '--json' in sys.argv:
        print('\n' + json.dumps(result, ensure_ascii=False, indent=2))

    sys.exit(0 if result['success'] else 1)

if __name__ == "__main__":
    main()
