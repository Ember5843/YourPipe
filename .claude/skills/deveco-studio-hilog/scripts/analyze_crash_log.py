#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
HarmonyOS模拟器崩溃日志分析脚本（macOS/Linux版本）

自动解压和分析HarmonyOS模拟器的崩溃日志。
它会查找最新的崩溃报告文件，解压崩溃报告，解压hilog_tmp_xxx文件夹中的.gz日志，
并显示崩溃摘要信息。
"""

import os
import sys
import json
import zipfile
import gzip
import shutil
import argparse
from pathlib import Path
from datetime import datetime

# 控制台编码设置
if sys.platform == "win32":
    import io
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8', errors='replace')

def print_banner():
    """打印横幅"""
    print("\033[36m=== HarmonyOS 模拟器崩溃日志分析 ===\033[0m")

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

def normalize_path(path):
    """规范化路径"""
    if not path:
        return None
    return os.path.abspath(path)

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

def find_emulator_instance():
    """自动查找模拟器实例路径"""
    print_color("正在查找模拟器实例路径...", "yellow")

    # 优先级1：尝试从环境变量获取
    env_path = os.environ.get("EMULATOR_INSTANCE_PATH")
    if env_path and os.path.exists(env_path):
        print_color(f"从环境变量找到实例路径: {env_path}", "green")
        return env_path

    # 优先级2：尝试从配置文件获取
    config = get_config()
    if config and config.get("emulatorInstancePath"):
        config_path = config["emulatorInstancePath"]
        if config_path and os.path.exists(config_path):
            print_color(f"从配置文件找到实例路径: {config_path}", "green")
            return config_path
        else:
            print_color(f"警告: 配置文件中的实例路径不存在: {config_path}", "yellow")

    # 优先级3：尝试从配置文件获取部署路径，然后查找实例
    if config and config.get("emulatorDeployPath"):
        deploy_path = config["emulatorDeployPath"]
        if deploy_path and os.path.exists(deploy_path):
            instances = [d for d in os.listdir(deploy_path) if os.path.isdir(os.path.join(deploy_path, d))]
            if instances:
                print_color(f"从配置文件找到部署路径: {deploy_path}", "green")
                print_color("找到以下模拟器实例:", "cyan")
                for instance in instances:
                    print_color(f"  - {instance}", "white")
                print_color("")
                print_color("请使用 --instance-path 参数指定实例路径", "yellow")
                first_instance = os.path.join(deploy_path, instances[0])
                print_color(f"例如: python analyze_crash_log.py --instance-path '{first_instance}'", "cyan")
                return None

    # 优先级4：尝试常见路径
    if sys.platform == "win32":
        localappdata = os.environ.get("LOCALAPPDATA") or ""
        userprofile = os.environ.get("USERPROFILE") or ""
        common_paths = [
            os.path.join(localappdata, "Huawei", "emulator", "deployed"),
            os.path.join(userprofile, "Huawei", "emulator", "deployed"),
            os.path.join(userprofile, "emu", "deployed"),
        ]
    elif sys.platform == "darwin":
        common_paths = [
            os.path.expanduser("~/Library/Huawei/emulator/deployed"),
            os.path.expanduser("~/Huawei/emulator/deployed"),
        ]
    else:  # Linux
        common_paths = [
            os.path.expanduser("~/.local/share/Huawei/emulator/deployed"),
            os.path.expanduser("~/Huawei/emulator/deployed"),
        ]

    for base_path in common_paths:
        if os.path.exists(base_path):
            instances = [d for d in os.listdir(base_path) if os.path.isdir(os.path.join(base_path, d))]
            if instances:
                print_color("找到以下模拟器实例:", "cyan")
                for instance in instances:
                    print_color(f"  - {instance}", "white")
                print_color("")
                print_color("请使用 --instance-path 参数指定实例路径", "yellow")
                first_instance = os.path.join(base_path, instances[0])
                print_color(f"例如: python analyze_crash_log.py --instance-path '{first_instance}'", "cyan")
                return None

    print_color("未找到模拟器实例路径", "red")
    print_color("请使用 --instance-path 参数指定实例路径，或运行 setup.py 生成配置文件", "yellow")
    return None

def test_instance_path(path):
    """验证实例路径"""
    path = normalize_path(path)

    if not path:
        print_color("错误: 实例路径为空", "red")
        return False

    print_color(f"验证实例路径: {path}", "yellow")

    if not os.path.exists(path):
        print_color(f"错误: 实例路径不存在: {path}", "red")
        print_color("")
        print_color("调试信息:", "yellow")
        print_color("  请检查路径是否正确", "white")
        print_color("  请确保你有访问该路径的权限", "white")
        return False

    if not os.path.isdir(path):
        print_color(f"错误: 路径不是目录: {path}", "red")
        return False

    print_color("实例路径验证成功", "green")
    return True

def find_crash_log_dir(instance_path):
    """查找崩溃日志目录"""
    instance_path = normalize_path(instance_path)

    if not instance_path:
        print_color("错误: 实例路径为空", "red")
        return None

    # 尝试不同的路径格式
    possible_paths = [
        os.path.join(instance_path, "Log", "crash_report"),
        os.path.join(instance_path, "log", "crash_report"),
    ]

    for path in possible_paths:
        print_color(f"检查路径: {path}", "cyan")
        if os.path.exists(path):
            print_color(f"找到崩溃日志目录: {path}", "green")
            return path

    print_color("错误: 未找到崩溃日志目录", "red")
    print_color("")
    print_color("已尝试的路径:", "yellow")
    for path in possible_paths:
        print_color(f"  - {path}", "white")
    print_color("")
    print_color("调试信息:", "yellow")
    print_color("  请检查实例路径下是否存在 Log/crash_report 目录", "white")
    print_color("  请确保模拟器已发生过崩溃", "white")
    return None

def find_crash_report_file(crash_log_dir, crash_report_path=None):
    """查找崩溃报告文件"""
    if crash_report_path:
        crash_report_file = os.path.join(crash_log_dir, crash_report_path)
        if os.path.exists(crash_report_file):
            print_color(f"找到指定的崩溃报告文件: {crash_report_path}", "green")
            return crash_report_file
        else:
            print_color(f"错误: 指定的崩溃报告文件不存在: {crash_report_file}", "red")
            return None

    # 查找最新的崩溃报告文件
    print_color("查找最新的崩溃报告文件...", "yellow")
    crash_report_files = [f for f in os.listdir(crash_log_dir) if f.startswith("crash_report-") and f.endswith(".zip")]

    if not crash_report_files:
        print_color("错误: 未找到崩溃报告文件", "red")
        print_color("")
        print_color("调试信息:", "yellow")
        print_color("  请确保崩溃报告文件存在", "white")
        print_color("  崩溃报告文件格式: crash_report-YYYY-MM-DDTHHMMSS.zip", "white")
        return None

    # 按修改时间排序
    crash_report_files_with_time = []
    for f in crash_report_files:
        file_path = os.path.join(crash_log_dir, f)
        mtime = os.path.getmtime(file_path)
        crash_report_files_with_time.append((mtime, f))

    crash_report_files_with_time.sort(reverse=True)
    latest_file = crash_report_files_with_time[0][1]
    latest_file_path = os.path.join(crash_log_dir, latest_file)

    print_color(f"找到最新的崩溃报告文件: {latest_file}", "green")
    file_size = os.path.getsize(latest_file_path) / 1024
    print_color(f"文件大小: {file_size:.2f} KB", "cyan")
    print_color(f"修改时间: {datetime.fromtimestamp(crash_report_files_with_time[0][0])}", "cyan")

    return latest_file_path

def extract_zip(zip_file, extract_dir):
    """解压zip文件"""
    try:
        with zipfile.ZipFile(zip_file, 'r') as zip_ref:
            zip_ref.extractall(extract_dir)
        return True
    except Exception as e:
        print_color(f"错误: 解压失败: {e}", "red")
        print_color("")
        print_color("调试信息:", "yellow")
        print_color("  请检查文件是否损坏", "white")
        print_color("  请检查是否有足够的磁盘空间", "white")
        print_color("  请检查是否有写入权限", "white")
        return False

def extract_gz_files(directory):
    """解压目录中的.gz文件"""
    gz_files = [f for f in os.listdir(directory) if f.endswith(".gz")]

    if not gz_files:
        return {"success": True, "total_files": 0, "success_count": 0, "fail_count": 0, "files": []}

    print_color(f"  找到 {len(gz_files)} 个.gz文件", "cyan")

    success_count = 0
    fail_count = 0
    files_info = []

    for gz_file in gz_files:
        gz_file_path = os.path.join(directory, gz_file)
        output_file = gz_file_path[:-3]  # 移除 .gz

        file_info = {"gz_file": gz_file, "success": False, "error": None}

        try:
            with gzip.open(gz_file_path, 'rb') as f_in:
                with open(output_file, 'wb') as f_out:
                    f_out.write(f_in.read())
            print_color(f"  解压成功: {os.path.basename(output_file)}", "green")
            success_count += 1
            file_info["success"] = True
        except Exception as e:
            print_color(f"  解压失败: {gz_file}: {e}", "red")
            fail_count += 1
            file_info["error"] = str(e)

        files_info.append(file_info)

    print_color(f"  解压完成: 成功 {success_count} 个，失败 {fail_count} 个", "green")

    return {
        "success": True,
        "total_files": len(gz_files),
        "success_count": success_count,
        "fail_count": fail_count,
        "files": files_info
    }

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
    parser = argparse.ArgumentParser(description="HarmonyOS模拟器崩溃日志分析")
    parser.add_argument("--instance-path", help="模拟器实例路径")
    parser.add_argument("--crash-report-path", help="指定崩溃报告文件名")
    parser.add_argument("--no-auto-find", action="store_true", help="禁用自动查找")

    args = parser.parse_args()

    print_banner()
    print_color("")

    # 获取实例路径
    instance_path = args.instance_path
    if not instance_path:
        if not args.no_auto_find:
            instance_path = find_emulator_instance()
            if not instance_path:
                sys.exit(1)
        else:
            print_color("错误: 请提供实例路径或使用自动查找", "red")
            sys.exit(1)

    # 验证实例路径
    if not test_instance_path(instance_path):
        sys.exit(1)

    # 规范化路径
    instance_path = normalize_path(instance_path)

    # 查找崩溃日志目录
    crash_log_dir = find_crash_log_dir(instance_path)
    if not crash_log_dir:
        sys.exit(1)

    # 查找崩溃报告文件
    crash_report_file = find_crash_report_file(crash_log_dir, args.crash_report_path)
    if not crash_report_file:
        sys.exit(1)

    # 创建解压目录
    extract_dir = os.path.join(crash_log_dir, "crash_report_extracted")
    print_color("")
    print_color(f"创建解压目录: {extract_dir}", "yellow")

    if os.path.exists(extract_dir):
        print_color("删除旧的解压目录...", "cyan")
        shutil.rmtree(extract_dir)

    os.makedirs(extract_dir, exist_ok=True)

    # 解压崩溃报告
    print_color("")
    print_color("正在解压崩溃报告...", "yellow")
    if not extract_zip(crash_report_file, extract_dir):
        sys.exit(1)

    print_color("解压完成", "green")

    # 解压hilog_tmp_xxx文件夹中的.gz日志
    hilog_dirs = [d for d in os.listdir(extract_dir) if d.startswith("hilog_tmp_") and os.path.isdir(os.path.join(extract_dir, d))]
    if hilog_dirs:
        print_color("")
        print_color("正在解压hilog日志...", "yellow")

        for dir_name in hilog_dirs:
            hilog_dir = os.path.join(extract_dir, dir_name)
            print_color(f"  解压目录: {dir_name}", "cyan")
            extract_gz_files(hilog_dir)

        print_color("hilog日志解压完成", "green")

    # 显示崩溃摘要信息
    print_color("")
    print_color("=== 崩溃摘要 ===", "yellow")

    details_file = os.path.join(extract_dir, "details.txt")
    if os.path.exists(details_file):
        print_color("")
        print_color("--- 崩溃详情 ---", "cyan")
        try:
            with open(details_file, 'r', encoding='utf-8', errors='ignore') as f:
                print(f.read())
        except Exception as e:
            print_color(f"读取文件失败: {e}", "yellow")

    reproduction_file = os.path.join(extract_dir, "reproductionsteps.txt")
    if os.path.exists(reproduction_file):
        print_color("")
        print_color("--- 崩溃前的操作 ---", "cyan")
        try:
            with open(reproduction_file, 'r', encoding='utf-8', errors='ignore') as f:
                print(f.read())
        except Exception as e:
            print_color(f"读取文件失败: {e}", "yellow")

    # 显示文件列表
    print_color("")
    print_color("=== 解压后的文件 ===", "yellow")
    print_files_recursive(extract_dir)

    # 生成分析报告
    report_file = os.path.join(crash_log_dir, "crash_analysis_report.txt")
    print_color("")
    print_color("=== 生成分析报告 ===", "yellow")

    report_content = "HarmonyOS模拟器崩溃日志分析报告\n"
    report_content += "====================================\n\n"
    report_content += f"分析时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n"
    report_content += f"实例路径: {instance_path}\n"
    report_content += f"崩溃报告: {os.path.basename(crash_report_file)}\n"
    report_content += f"解压目录: {extract_dir}\n"
    report_content += "\n---\n\n"

    if os.path.exists(details_file):
        report_content += "[崩溃详情]\n\n"
        try:
            with open(details_file, 'r', encoding='utf-8', errors='ignore') as f:
                report_content += f.read()
        except Exception:
            pass
        report_content += "\n\n"

    if os.path.exists(reproduction_file):
        report_content += "[崩溃前的操作]\n\n"
        try:
            with open(reproduction_file, 'r', encoding='utf-8', errors='ignore') as f:
                report_content += f.read()
        except Exception:
            pass
        report_content += "\n\n"

    try:
        with open(report_file, 'w', encoding='utf-8') as f:
            f.write(report_content)
        print_color(f"分析报告已保存到: {report_file}", "green")
    except Exception as e:
        print_color(f"保存报告失败: {e}", "yellow")

    print_color("")
    print_color("分析完成！", "green")
    print_color(f"解压目录: {extract_dir}", "cyan")
    print_color(f"分析报告: {report_file}", "cyan")

if __name__ == "__main__":
    main()
