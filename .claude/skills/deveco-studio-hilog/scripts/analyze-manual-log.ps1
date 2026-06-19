<#
.SYNOPSIS
    自动查找、解压和分析HarmonyOS模拟器手动保存的日志

.DESCRIPTION
    此脚本用于自动查找、解压和分析HarmonyOS模拟器手动保存的日志。
    它会查找DevEco Studio日志目录，查找最新的bugreport文件，解压bugreport文件，
    解压SystemLog文件夹中的.gz日志，并显示日志摘要信息。

.PARAMETER DevEcoVersion
    DevEco Studio版本（可选，默认自动查找）

.PARAMETER BugReportPath
    指定bugreport文件名（可选，默认使用最新的）

.EXAMPLE
    .\analyze-manual-log.ps1

.EXAMPLE
    .\analyze-manual-log.ps1 -DevEcoVersion "7.0"

.EXAMPLE
    .\analyze-manual-log.ps1 -BugReportPath "bugreport-2026-03-16T231455.zip"
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$DevEcoVersion,

    [Parameter(Mandatory=$false)]
    [string]$BugReportPath
)

# 函数：读取配置文件（优先从 deveco-studio-emulator skill 读取）
function Get-Config {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    
    # 优先级1：从 deveco-studio-emulator skill 读取配置
    $emulatorConfigFile = Join-Path $scriptDir "..\..\deveco-studio-emulator\scripts\config.json"
    
    if (Test-Path $emulatorConfigFile) {
        try {
            $config = Get-Content $emulatorConfigFile -Raw | ConvertFrom-Json
            Write-Host "已加载配置文件: $emulatorConfigFile" -ForegroundColor DarkGray
            return $config
        } catch {
            Write-Host "警告: 配置文件格式错误: $_" -ForegroundColor Yellow
        }
    }
    
    # 优先级2：从当前目录读取配置（兼容旧版本）
    $localConfigFile = Join-Path $scriptDir "..\config.json"
    
    if (Test-Path $localConfigFile) {
        try {
            $config = Get-Content $localConfigFile -Raw | ConvertFrom-Json
            Write-Host "已加载配置文件: $localConfigFile" -ForegroundColor DarkGray
            return $config
        } catch {
            Write-Host "警告: 配置文件格式错误: $_" -ForegroundColor Yellow
        }
    }
    
    Write-Host "提示: 未找到配置文件，将使用环境变量或自动查找" -ForegroundColor DarkGray
    Write-Host "提示: 请运行 python ../deveco-studio-emulator/scripts/setup.py 初始化配置" -ForegroundColor Yellow
    return $null
}

# 查找DevEco Studio日志目录
function Find-DevEcoLogDir {
    param([string]$Version)

    if ($Version) {
        $logDir = Join-Path $env:LOCALAPPDATA "Huawei\DevEcoStudio$Version\log"
        if (Test-Path $logDir) {
            return $logDir
        }
        return $null
    }

    # 自动查找
    $logDirs = @(
        Join-Path $env:LOCALAPPDATA "Huawei\DevEcoStudio7.0\log",
        Join-Path $env:LOCALAPPDATA "Huawei\DevEcoStudio6.1\log",
        Join-Path $env:LOCALAPPDATA "Huawei\DevEcoStudio\log"
    )

    foreach ($dir in $logDirs) {
        if (Test-Path $dir) {
            return $dir
        }
    }

    return $null
}

# 查找日志目录
$logDir = Find-DevEcoLogDir -Version $DevEcoVersion

if (-not $logDir) {
    Write-Host "错误: 未找到DevEco Studio日志目录" -ForegroundColor Red
    Write-Host "请检查DevEco Studio是否正确安装" -ForegroundColor Yellow
    exit 1
}

Write-Host "找到日志目录: $logDir" -ForegroundColor Green

# 查找bugreport文件
if ($BugReportPath) {
    $bugReportFile = Join-Path $logDir $BugReportPath
    if (-not (Test-Path $bugReportFile)) {
        Write-Host "错误: bugreport文件不存在: $bugReportFile" -ForegroundColor Red
        exit 1
    }
} else {
    # 查找最新的bugreport文件
    $bugReportFile = Get-ChildItem -Path $logDir -Filter "bugreport-*.zip" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $bugReportFile) {
        Write-Host "错误: 未找到bugreport文件" -ForegroundColor Red
        Write-Host "请确保已手动保存过日志" -ForegroundColor Yellow
        exit 1
    }
}

Write-Host "找到bugreport文件: $($bugReportFile.Name)" -ForegroundColor Green

# 创建解压目录
$extractDir = Join-Path $logDir "bugreport_extracted"
if (Test-Path $extractDir) {
    Remove-Item -Path $extractDir -Recurse -Force
}
New-Item -Path $extractDir -ItemType Directory | Out-Null

# 解压bugreport文件
Write-Host "正在解压bugreport文件..." -ForegroundColor Yellow
try {
    Expand-Archive -Path $bugReportFile.FullName -DestinationPath $extractDir -Force
    Write-Host "解压完成" -ForegroundColor Green
} catch {
    Write-Host "错误: 解压失败: $_" -ForegroundColor Red
    exit 1
}

# 解压SystemLog文件夹中的.gz日志
$systemLogDir = Join-Path $extractDir "SystemLog"
if (Test-Path $systemLogDir) {
    Write-Host ""
    Write-Host "正在解压SystemLog..." -ForegroundColor Yellow

    # 检查Python是否可用
    $pythonAvailable = $false
    try {
        $pythonVersion = python --version 2>&1
        if ($pythonVersion -match "Python") {
            $pythonAvailable = $true
            Write-Host "使用Python解压.gz文件" -ForegroundColor DarkGray
        }
    } catch {
        # Python不可用
    }

    if (-not $pythonAvailable) {
        Write-Host "警告: 未找到Python，跳过.gz文件解压" -ForegroundColor Yellow
        Write-Host "请安装Python: https://www.python.org/" -ForegroundColor Yellow
    } else {
        $gzipFiles = Get-ChildItem -Path $systemLogDir -Filter "*.gz" -ErrorAction SilentlyContinue
        if ($gzipFiles) {
            Write-Host "  找到 $($gzipFiles.Count) 个.gz文件" -ForegroundColor Cyan

            # 创建Python脚本来解压.gz文件
            $pythonScript = @"
import os
import gzip
import sys

system_log_dir = r'$systemLogDir'
gz_files = [os.path.join(system_log_dir, f) for f in os.listdir(system_log_dir) if f.endswith('.gz')]

success_count = 0
fail_count = 0

for gz_file in gz_files:
    filename = os.path.basename(gz_file)
    print(f"解压文件: {filename}")
    
    output_file = gz_file[:-3]  # 移除 .gz
    
    try:
        with gzip.open(gz_file, 'rb') as f_in:
            with open(output_file, 'wb') as f_out:
                f_out.write(f_in.read())
        print(f"  解压成功: {os.path.basename(output_file)}")
        success_count += 1
    except Exception as e:
        print(f"  解压失败: {e}")
        fail_count += 1

print(f"解压完成: 成功 {success_count} 个，失败 {fail_count} 个")
sys.exit(0)
"@

            $tempScript = Join-Path $env:TEMP "extract_hilog_$([Guid]::NewGuid()).py"
            $pythonScript | Out-File -FilePath $tempScript -Encoding UTF8

            try {
                python $tempScript
            } catch {
                Write-Host "  警告: Python脚本执行失败: $_" -ForegroundColor Yellow
            } finally {
                # 删除临时脚本
                Remove-Item -Path $tempScript -Force -ErrorAction SilentlyContinue
            }
        } else {
            Write-Host "  未找到.gz文件" -ForegroundColor Yellow
        }
        Write-Host "SystemLog解压完成" -ForegroundColor Green
    }
}

# 显示日志摘要信息
Write-Host "`n=== 日志摘要 ===" -ForegroundColor Yellow

if ($detailsFile = Join-Path $extractDir "details.json"; Test-Path $detailsFile) {
    Write-Host "`n--- 基本信息 ---" -ForegroundColor Cyan
    try {
        $details = Get-Content $detailsFile | ConvertFrom-Json
        $details | Format-List
    } catch {
        Write-Host "警告: 无法解析details.json" -ForegroundColor Yellow
    }
}

# 显示文件列表
Write-Host "`n=== 解压后的文件 ===" -ForegroundColor Yellow
Get-ChildItem -Path $extractDir -Recurse | ForEach-Object {
    $relativePath = $_.FullName.Substring($extractDir.Length + 1)
    $size = if ($_.PSIsContainer) { "<DIR>" } else { "{0:N2} KB" -f ($_.Length / 1KB) }
    Write-Host "  $relativePath ($size)"
}

# 生成分析报告
$reportFile = Join-Path $logDir "manual_log_analysis_report.txt"
Write-Host "`n=== 生成分析报告 ===" -ForegroundColor Yellow

$reportContent = "HarmonyOS模拟器手动保存日志分析报告"
$reportContent += "`n=====================================`n`n"
$reportContent += "分析时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"
$reportContent += "日志目录: $logDir`n"
$reportContent += "BugReport文件: $($bugReportFile.Name)`n"
$reportContent += "解压目录: $extractDir`n"
$reportContent += "`n---`n`n"

$reportContent | Out-File -FilePath $reportFile -Encoding UTF8

if (Test-Path (Join-Path $extractDir "details.json")) {
    $reportContent += "【基本信息】`n`n"
    try {
        $details = Get-Content (Join-Path $extractDir "details.json") | ConvertFrom-Json
        $reportContent += $details | Format-List | Out-String
    } catch {
        $reportContent += "无法解析details.json`n"
    }
    $reportContent += "`n`n"
}

if (Test-Path (Join-Path $extractDir "Emulator.log")) {
    $reportContent += "【模拟器日志错误】`n`n"
    $errors = Get-Content (Join-Path $extractDir "Emulator.log") | Select-String -Pattern "Error|error|ERROR"
    if ($errors) {
        $reportContent += $errors | Out-String
    } else {
        $reportContent += "未找到错误信息`n"
    }
    $reportContent += "`n`n"
}

if (Test-Path (Join-Path $extractDir "kernel.log")) {
    $reportContent += "【内核日志错误】`n`n"
    $errors = Get-Content (Join-Path $extractDir "kernel.log") | Select-String -Pattern "Error|error|ERROR"
    if ($errors) {
        $reportContent += $errors | Out-String
    } else {
        $reportContent += "未找到错误信息`n"
    }
    $reportContent += "`n`n"
}

if (Test-Path $systemLogDir) {
    $reportContent += "【SystemLog错误】`n`n"
    $logFiles = Get-ChildItem -Path $systemLogDir -Filter "*.log"
    if ($logFiles) {
        foreach ($logFile in $logFiles) {
            $reportContent += "文件: $($logFile.Name)`n"
            $errors = Get-Content $logFile.FullName | Select-String -Pattern "Error|error|ERROR|Exception"
            if ($errors) {
                $reportContent += $errors | Out-String
            } else {
                $reportContent += "  未找到错误信息`n"
            }
            $reportContent += "`n"
        }
    } else {
        $reportContent += "未找到日志文件`n"
    }
    $reportContent += "`n`n"
}

$reportContent | Out-File -FilePath $reportFile -Encoding UTF8 -Append

Write-Host "分析报告已保存到: $reportFile" -ForegroundColor Green

# 显示截图信息
$screenshotFile = Join-Path $extractDir "screenshot.png"
if (Test-Path $screenshotFile) {
    Write-Host "`n=== 截图 ===" -ForegroundColor Yellow
    Write-Host "截图文件: $screenshotFile" -ForegroundColor Cyan
    Write-Host "可以使用图片查看器打开截图" -ForegroundColor Yellow
}

Write-Host "`n分析完成！" -ForegroundColor Green
Write-Host "解压目录: $extractDir" -ForegroundColor Cyan
Write-Host "分析报告: $reportFile" -ForegroundColor Cyan
