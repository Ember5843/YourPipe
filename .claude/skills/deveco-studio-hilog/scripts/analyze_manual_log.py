#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
HarmonyOS模拟器手动保存日志分析脚本（macOS/Linux版本）

自动查找、解压和分析HarmonyOS模拟器手动保存的日志。
它会查找DevEco Studio日志目录，查找最新的bugreport文件，解压bugreport文件，
解压SystemLog文件夹中的.gz日志，并显示日志摘要信息。
"""

import os
import sys
import json
import zipfile
import gzip
import shutil
import argparse
import re
from pathlib import Path
from datetime import datetime

# 控制台编码设置
if sys.platform == "win32":
    import io
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8', errors='replace')

def print_banner():
    """打印横幅"""
    print("\033[36m=== HarmonyOS 模拟器手动保存日志分析 ===\033[0m")

def print_color(message, color="white"):
    """打印彩色消息"""
    colors = {
        "red": "\033[31m",
        "green": "\033[32m",
        "yellow": "\033[33m",
        "blue": "\033[34m",
        "magenta": "\033[35m",
        "cyan": "\033[36m",
        "white": "\033[37m",
        "reset": "\033[0m"
    }
    print(f"{colors.get(color, colors['white'])}{message}{colors['reset']}")

def get_config():
    """读取配置文件（优先从 deveco-studio-emulator skill 读取）"""
    # 优先级1：从 deveco-studio-emulator skill 读取配置
    script_dir = Path(__file__).parent.parent
    emulator_config_file = script_dir.parent / "deveco-studio-emulator" / "scripts" / "config.json"
    
    if emulator_config_file.exists():
        try:
            with open(emulator_config_file, 'r', encoding='utf-8') as f:
                config = json.load(f)
            print_color(f"已加载配置文件: {emulator_config_file}", "cyan")
            return config
        except Exception as e:
            print_color(f"警告: 配置文件格式错误: {e}", "yellow")
    
    # 优先级2：从当前目录读取配置（兼容旧版本）
    local_config_file = script_dir / "config.json"
    if local_config_file.exists():
        try:
            with open(local_config_file, 'r', encoding='utf-8') as f:
                config = json.load(f)
            print_color(f"已加载配置文件: {local_config_file}", "cyan")
            return config
        except Exception as e:
            print_color(f"警告: 配置文件格式错误: {e}", "yellow")
    
    print_color("提示: 未找到配置文件，将使用环境变量或自动查找", "cyan")
    print_color("提示: 请运行 python ../deveco-studio-emulator/scripts/setup.py 初始化配置", "yellow")
    return None

def find_deveco_log_dir(version=None):
    """查找DevEco Studio日志目录"""
    if version:
        if sys.platform == "win32":
            log_dir = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Huawei", f"DevEcoStudio{version}", "log")
        elif sys.platform == "darwin":
            log_dir = os.path.expanduser(f"~/Library/Huawei/DevEcoStudio{version}/log")
        else:  # Linux
            log_dir = os.path.expanduser(f"~/.local/share/Huawei/DevEcoStudio{version}/log")

        if os.path.exists(log_dir):
            return log_dir
        return None

    # 自动查找
    if sys.platform == "win32":
        log_dirs = [
            os.path.join(os.environ.get("LOCALAPPDATA", ""), "Huawei", "DevEcoStudio7.0", "log"),
            os.path.join(os.environ.get("LOCALAPPDATA", ""), "Huawei", "DevEcoStudio6.1", "log"),
            os.path.join(os.environ.get("LOCALAPPDATA", ""), "Huawei", "DevEcoStudio", "log"),
        ]
    elif sys.platform == "darwin":
        log_dirs = [
            os.path.expanduser("~/Library/Huawei/DevEcoStudio7.0/log"),
            os.path.expanduser("~/Library/Huawei/DevEcoStudio6.1/log"),
            os.path.expanduser("~/Library/Huawei/DevEcoStudio/log"),
        ]
    else:  # Linux
        log_dirs = [
            os.path.expanduser("~/.local/share/Huawei/DevEcoStudio7.0/log"),
            os.path.expanduser("~/.local/share/Huawei/DevEcoStudio6.1/log"),
            os.path.expanduser("~/.local/share/Huawei/DevEcoStudio/log"),
        ]

    for log_dir in log_dirs:
        if os.path.exists(log_dir):
            return log_dir

    return None

def extract_zip(zip_file, extract_dir):
    """解压zip文件"""
    try:
        with zipfile.ZipFile(zip_file, 'r') as zip_ref:
            zip_ref.extractall(extract_dir)
        return True
    except Exception as e:
        print_color(f"错误: 解压失败: {e}", "red")
        return False

def extract_gz_files(directory):
    """解压目录中的.gz文件"""
    gz_files = [f for f in os.listdir(directory) if f.endswith(".gz")]

    if not gz_files:
        return {"success": True, "total_files": 0, "success_count": 0, "fail_count": 0}

    print_color(f"  找到 {len(gz_files)} 个.gz文件", "cyan")

    success_count = 0
    fail_count = 0

    for gz_file in gz_files:
        gz_file_path = os.path.join(directory, gz_file)
        output_file = gz_file_path[:-3]  # 移除 .gz

        try:
            with gzip.open(gz_file_path, 'rb') as f_in:
                with open(output_file, 'wb') as f_out:
                    f_out.write(f_in.read())
            print_color(f"  解压成功: {os.path.basename(output_file)}", "green")
            success_count += 1
        except Exception as e:
            print_color(f"  解压失败: {gz_file}: {e}", "red")
            fail_count += 1

    print_color(f"  解压完成: 成功 {success_count} 个，失败 {fail_count} 个", "green")

    return {
        "success": True,
        "total_files": len(gz_files),
        "success_count": success_count,
        "fail_count": fail_count
    }

def find_errors_in_file(file_path, patterns=None):
    """在文件中查找错误信息"""
    if not os.path.exists(file_path):
        return []

    if patterns is None:
        patterns = [r"Error", r"error", r"ERROR", r"Exception", r"exception", r"EXCEPTION"]

    errors = []
    try:
        with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
            for line_num, line in enumerate(f, 1):
                for pattern in patterns:
                    if re.search(pattern, line):
                        errors.append(f"  [{line_num}] {line.strip()}")
                        break
    except Exception as e:
        print_color(f"  读取文件失败: {e}", "yellow")

    return errors

def print_files_recursive(directory, prefix=""):
    """递归打印文件"""
    try:
        items = sorted(os.listdir(directory))
    except Exception as e:
        print_color(f"无法读取目录: {e}", "yellow")
        return

    for i, item in enumerate(items):
        item_path = os.path.join(directory, item)
        is_last = i == len(items) - 1
        current_prefix = "└── " if is_last else "├── "
        next_prefix = "    " if is_last else "│   "

        if os.path.isdir(item_path):
            print(f"{prefix}{current_prefix}{item}/")
            print_files_recursive(item_path, prefix + next_prefix)
        else:
            try:
                size = os.path.getsize(item_path) / 1024
                print(f"{prefix}{current_prefix}{item} ({size:.2f} KB)")
            except Exception:
                print(f"{prefix}{current_prefix}{item}")

def main():
    """主函数"""
    parser = argparse.ArgumentParser(description="HarmonyOS模拟器手动保存日志分析")
    parser.add_argument("--deveco-version", help="DevEco Studio版本")
    parser.add_argument("--bug-report-path", help="指定bugreport文件名")

    args = parser.parse_args()

    print_banner()
    print_color("")

    # 查找日志目录
    log_dir = find_deveco_log_dir(args.deveco_version)

    if not log_dir:
        print_color("错误: 未找到DevEco Studio日志目录", "red")
        print_color("请检查DevEco Studio是否正确安装", "yellow")
        sys.exit(1)

    print_color(f"找到日志目录: {log_dir}", "green")

    # 查找bugreport文件
    if args.bug_report_path:
        bug_report_file = os.path.join(log_dir, args.bug_report_path)
        if not os.path.exists(bug_report_file):
            print_color(f"错误: bugreport文件不存在: {bug_report_file}", "red")
            sys.exit(1)
    else:
        # 查找最新的bugreport文件
        bug_report_files = [f for f in os.listdir(log_dir) if f.startswith("bugreport-") and f.endswith(".zip")]
        if not bug_report_files:
            print_color("错误: 未找到bugreport文件", "red")
            print_color("请确保已手动保存过日志", "yellow")
            sys.exit(1)

        # 按修改时间排序
        bug_report_files_with_time = []
        for f in bug_report_files:
            file_path = os.path.join(log_dir, f)
            mtime = os.path.getmtime(file_path)
            bug_report_files_with_time.append((mtime, f))

        bug_report_files_with_time.sort(reverse=True)
        latest_file = bug_report_files_with_time[0][1]
        bug_report_file = os.path.join(log_dir, latest_file)

    print_color(f"找到bugreport文件: {os.path.basename(bug_report_file)}", "green")

    # 创建解压目录
    extract_dir = os.path.join(log_dir, "bugreport_extracted")
    if os.path.exists(extract_dir):
        shutil.rmtree(extract_dir)
    os.makedirs(extract_dir, exist_ok=True)

    # 解压bugreport文件
    print_color("正在解压bugreport文件...", "yellow")
    if not extract_zip(bug_report_file, extract_dir):
        sys.exit(1)

    print_color("解压完成", "green")

    # 解压SystemLog文件夹中的.gz日志
    system_log_dir = os.path.join(extract_dir, "SystemLog")
    if os.path.exists(system_log_dir):
        print_color("")
        print_color("正在解压SystemLog...", "yellow")

        result = extract_gz_files(system_log_dir)
        print_color("SystemLog解压完成", "green")

    # 显示日志摘要信息
    print_color("")
    print_color("=== 日志摘要 ===", "yellow")

    details_file = os.path.join(extract_dir, "details.json")
    if os.path.exists(details_file):
        print_color("")
        print_color("--- 基本信息 ---", "cyan")
        try:
            with open(details_file, 'r', encoding='utf-8') as f:
                details = json.load(f)
            for key, value in details.items():
                print(f"  {key}: {value}")
        except Exception as e:
            print_color(f"警告: 无法解析details.json: {e}", "yellow")

    # 显示文件列表
    print_color("")
    print_color("=== 解压后的文件 ===", "yellow")
    print_files_recursive(extract_dir)

    # 生成分析报告
    report_file = os.path.join(log_dir, "manual_log_analysis_report.txt")
    print_color("")
    print_color("=== 生成分析报告 ===", "yellow")

    report_content = "HarmonyOS模拟器手动保存日志分析报告\n"
    report_content += "=====================================\n\n"
    report_content += f"分析时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n"
    report_content += f"日志目录: {log_dir}\n"
    report_content += f"BugReport文件: {os.path.basename(bug_report_file)}\n"
    report_content += f"解压目录: {extract_dir}\n"
    report_content += "\n---\n\n"

    if os.path.exists(details_file):
        report_content += "【基本信息】\n\n"
        try:
            with open(details_file, 'r', encoding='utf-8') as f:
                details = json.load(f)
            for key, value in details.items():
                report_content += f"{key}: {value}\n"
        except Exception as e:
            report_content += f"无法解析details.json: {e}\n"
        report_content += "\n\n"

    if os.path.exists(os.path.join(extract_dir, "Emulator.log")):
        report_content += "【模拟器日志错误】\n\n"
        errors = find_errors_in_file(os.path.join(extract_dir, "Emulator.log"))
        if errors:
            report_content += "\n".join(errors[:20])  # 限制输出前20行
            if len(errors) > 20:
                report_content += f"\n  ... 还有 {len(errors) - 20} 条错误信息"
        else:
            report_content += "未找到错误信息\n"
        report_content += "\n\n"

    if os.path.exists(os.path.join(extract_dir, "kernel.log")):
        report_content += "【内核日志错误】\n\n"
        errors = find_errors_in_file(os.path.join(extract_dir, "kernel.log"))
        if errors:
            report_content += "\n".join(errors[:20])
            if len(errors) > 20:
                report_content += f"\n  ... 还有 {len(errors) - 20} 条错误信息"
        else:
            report_content += "未找到错误信息\n"
        report_content += "\n\n"

    if os.path.exists(system_log_dir):
        report_content += "【SystemLog错误】\n\n"
        log_files = [f for f in os.listdir(system_log_dir) if f.endswith(".log")]
        if log_files:
            for log_file in log_files[:5]:  # 限制处理前5个文件
                log_file_path = os.path.join(system_log_dir, log_file)
                report_content += f"文件: {log_file}\n"
                errors = find_errors_in_file(log_file_path)
                if errors:
                    report_content += "\n".join(errors[:10])
                    if len(errors) > 10:
                        report_content += f"\n  ... 还有 {len(errors) - 10} 条错误信息"
                else:
                    report_content += "  未找到错误信息\n"
                report_content += "\n"
        else:
            report_content += "未找到日志文件\n"
        report_content += "\n\n"

    try:
        with open(report_file, 'w', encoding='utf-8') as f:
            f.write(report_content)
        print_color(f"分析报告已保存到: {report_file}", "green")
    except Exception as e:
        print_color(f"保存报告失败: {e}", "yellow")

    # 显示截图信息
    screenshot_file = os.path.join(extract_dir, "screenshot.png")
    if os.path.exists(screenshot_file):
        print_color("")
        print_color("=== 截图 ===", "yellow")
        print_color(f"截图文件: {screenshot_file}", "cyan")
        print_color("可以使用图片查看器打开截图", "yellow")

    print_color("")
    print_color("分析完成！", "green")
    print_color(f"解压目录: {extract_dir}", "cyan")
    print_color(f"分析报告: {report_file}", "cyan")

if __name__ == "__main__":
    main()
