<#
.SYNOPSIS
    自动解压和分析HarmonyOS模拟器崩溃日志

.DESCRIPTION
    此脚本用于自动解压和分析HarmonyOS模拟器的崩溃日志。
    它会查找最新的崩溃报告文件，解压崩溃报告，解压hilog_tmp_xxx文件夹中的.gz日志，
    并显示崩溃摘要信息。

.PARAMETER InstancePath
    模拟器实例路径（可选，如果不提供则自动查找）

.PARAMETER CrashReportPath
    指定崩溃报告文件名（可选，默认使用最新的）

.PARAMETER AutoFind
    自动查找模拟器实例路径（默认启用）

.EXAMPLE
    .\analyze-crash-log.ps1 -AutoFind

.EXAMPLE
    .\analyze-crash-log.ps1 -InstancePath "C:\Users\YourName\Huawei\emulator\deployed\MyPhone"

.EXAMPLE
    .\analyze-crash-log.ps1 -InstancePath "C:\Users\YourName\Huawei\emulator\deployed\MyPhone" -CrashReportPath "crash_report-2026-03-16T123249.zip"

.EXAMPLE
    .\analyze-crash-log.ps1 -AutoFind
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$InstancePath,

    [Parameter(Mandatory=$false)]
    [string]$CrashReportPath,

    [Parameter(Mandatory=$false)]
    [switch]$AutoFind = $true
)

# 设置错误处理
$ErrorActionPreference = "Stop"

# 函数：规范化路径
function Normalize-Path {
    param([string]$Path)

    if (-not $Path) {
        return $null
    }

    # 替换正斜杠为反斜杠
    $Path = $Path -replace '/', '\'

    # 移除结尾的反斜杠
    $Path = $Path.TrimEnd('\')

    # 转换为绝对路径
    try {
        $Path = (Resolve-Path -Path $Path -ErrorAction SilentlyContinue).Path
    } catch {
        # 如果无法解析，保持原样
    }

    return $Path
}

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

# 函数：自动查找模拟器实例路径
function Find-EmulatorInstance {
    Write-Host "正在查找模拟器实例路径..." -ForegroundColor Yellow

    # 优先级1：尝试从环境变量获取
    $envPath = $env:EMULATOR_INSTANCE_PATH
    if ($envPath -and (Test-Path $envPath)) {
        Write-Host "从环境变量找到实例路径: $envPath" -ForegroundColor Green
        return $envPath
    }

    # 优先级2：尝试从配置文件获取
    $config = Get-Config
    if ($config -and $config.emulatorInstancePath) {
        $configPath = $config.emulatorInstancePath
        if (Test-Path $configPath) {
            Write-Host "从配置文件找到实例路径: $configPath" -ForegroundColor Green
            return $configPath
        } else {
            Write-Host "警告: 配置文件中的实例路径不存在: $configPath" -ForegroundColor Yellow
        }
    }

    # 优先级3：尝试从配置文件获取部署路径，然后查找实例
    if ($config -and $config.emulatorDeployPath) {
        $deployPath = $config.emulatorDeployPath
        if (Test-Path $deployPath) {
            $instances = Get-ChildItem -Path $deployPath -Directory -ErrorAction SilentlyContinue
            if ($instances) {
                Write-Host "从配置文件找到部署路径: $deployPath" -ForegroundColor Green
                Write-Host "找到以下模拟器实例:" -ForegroundColor Cyan
                $instances | ForEach-Object { Write-Host "  - $($_.Name)" -ForegroundColor White }
                Write-Host ""
                Write-Host "请使用 -InstancePath 参数指定实例路径" -ForegroundColor Yellow
                Write-Host "例如: .\analyze-crash-log.ps1 -InstancePath '$($instances[0].FullName)'" -ForegroundColor Cyan
                return $null
            }
        }
    }

    # 优先级4：尝试常见路径（使用环境变量和通用路径）
    $commonPaths = @(
        Join-Path $env:LOCALAPPDATA "Huawei\emulator\deployed",
        Join-Path $env:USERPROFILE "Huawei\emulator\deployed",
        Join-Path $env:USERPROFILE "emu\deployed",
    )

    foreach ($basePath in $commonPaths) {
        if (Test-Path $basePath) {
            $instances = Get-ChildItem -Path $basePath -Directory -ErrorAction SilentlyContinue
            if ($instances) {
                Write-Host "找到以下模拟器实例:" -ForegroundColor Cyan
                $instances | ForEach-Object { Write-Host "  - $($_.Name)" -ForegroundColor White }
                Write-Host ""
                Write-Host "请使用 -InstancePath 参数指定实例路径" -ForegroundColor Yellow
                Write-Host "例如: .\analyze-crash-log.ps1 -InstancePath '$($instances[0].FullName)'" -ForegroundColor Cyan
                return $null
            }
        }
    }

    Write-Host "未找到模拟器实例路径" -ForegroundColor Red
    Write-Host "请使用 -InstancePath 参数指定实例路径，或运行 setup.py 生成配置文件" -ForegroundColor Yellow
    return $null
}

# 函数：验证实例路径
function Test-InstancePath {
    param([string]$Path)

    $Path = Normalize-Path -Path $Path

    if (-not $Path) {
        Write-Host "错误: 实例路径为空" -ForegroundColor Red
        return $false
    }

    Write-Host "验证实例路径: $Path" -ForegroundColor Yellow

    if (-not (Test-Path $Path)) {
        Write-Host "错误: 实例路径不存在: $Path" -ForegroundColor Red
        Write-Host ""
        Write-Host "调试信息:" -ForegroundColor Yellow
        Write-Host "  请检查路径是否正确" -ForegroundColor White
        Write-Host "  请确保路径中的空格已用引号包裹" -ForegroundColor White
        Write-Host "  请确保你有访问该路径的权限" -ForegroundColor White
        return $false
    }

    if (-not (Test-Path $Path -PathType Container)) {
        Write-Host "错误: 路径不是目录: $Path" -ForegroundColor Red
        return $false
    }

    Write-Host "实例路径验证成功" -ForegroundColor Green
    return $true
}

# 函数：查找崩溃日志目录
function Find-CrashLogDir {
    param([string]$InstancePath)

    $InstancePath = Normalize-Path -Path $InstancePath

    # 尝试不同的路径格式
    $possiblePaths = @(
        (Join-Path $InstancePath "Log\crash_report"),
        (Join-Path $InstancePath "Log/crash_report"),
        (Join-Path $InstancePath "log\crash_report"),
        (Join-Path $InstancePath "log/crash_report")
    )

    foreach ($path in $possiblePaths) {
        Write-Host "检查路径: $path" -ForegroundColor DarkGray
        if (Test-Path $path) {
            Write-Host "找到崩溃日志目录: $path" -ForegroundColor Green
            return $path
        }
    }

    Write-Host "错误: 未找到崩溃日志目录" -ForegroundColor Red
    Write-Host ""
    Write-Host "已尝试的路径:" -ForegroundColor Yellow
    $possiblePaths | ForEach-Object { Write-Host "  - $_" -ForegroundColor White }
    Write-Host ""
    Write-Host "调试信息:" -ForegroundColor Yellow
    Write-Host "  请检查实例路径下是否存在 Log\crash_report 目录" -ForegroundColor White
    Write-Host "  请确保模拟器已发生过崩溃" -ForegroundColor White
    return $null
}

# 函数：查找崩溃报告文件
function Find-CrashReportFile {
    param(
        [string]$CrashLogDir,
        [string]$CrashReportPath
    )

    if ($CrashReportPath) {
        $crashReportFile = Join-Path $CrashLogDir $CrashReportPath
        if (Test-Path $crashReportFile) {
            Write-Host "找到指定的崩溃报告文件: $CrashReportPath" -ForegroundColor Green
            return $crashReportFile
        } else {
            Write-Host "错误: 指定的崩溃报告文件不存在: $crashReportFile" -ForegroundColor Red
            return $null
        }
    }

    # 查找最新的崩溃报告文件
    Write-Host "查找最新的崩溃报告文件..." -ForegroundColor Yellow
    $crashReportFiles = Get-ChildItem -Path $CrashLogDir -Filter "crash_report-*.zip" -ErrorAction SilentlyContinue

    if (-not $crashReportFiles) {
        Write-Host "错误: 未找到崩溃报告文件" -ForegroundColor Red
        Write-Host ""
        Write-Host "调试信息:" -ForegroundColor Yellow
        Write-Host "  请确保崩溃报告文件存在" -ForegroundColor White
        Write-Host "  崩溃报告文件格式: crash_report-YYYY-MM-DDTHHMMSS.zip" -ForegroundColor White
        return $null
    }

    $latestFile = $crashReportFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    Write-Host "找到最新的崩溃报告文件: $($latestFile.Name)" -ForegroundColor Green
    Write-Host "文件大小: $("{0.2f} KB" -f ($latestFile.Length / 1KB))" -ForegroundColor DarkGray
    Write-Host "修改时间: $($latestFile.LastWriteTime)" -ForegroundColor DarkGray

    return $latestFile.FullName
}

# 函数：使用Python解压.gz文件
function Extract-GzFiles {
    param([string]$Directory)

    # 检查Python是否可用
    $pythonAvailable = $false
    try {
        $pythonVersion = python --version 2>&1
        if ($pythonVersion -match "Python") {
            $pythonAvailable = $true
        }
    } catch {
        # Python不可用
    }

    if (-not $pythonAvailable) {
        Write-Host "警告: 未找到Python，跳过.gz文件解压" -ForegroundColor Yellow
        Write-Host "请安装Python: https://www.python.org/" -ForegroundColor Yellow
        return $false
    }

    # 获取脚本目录
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $extractGzScript = Join-Path $scriptDir "extract_gz.py"

    if (-not (Test-Path $extractGzScript)) {
        Write-Host "警告: 未找到extract_gz.py脚本" -ForegroundColor Yellow
        return $false
    }

    # 调用Python脚本解压.gz文件
    try {
        $resultJson = python $extractGzScript $Directory | ConvertFrom-Json
        
        if ($resultJson.success) {
            Write-Host "  找到 $($resultJson.total_files) 个.gz文件" -ForegroundColor Cyan
            Write-Host "  解压完成: 成功 $($resultJson.success_count) 个，失败 $($resultJson.fail_count) 个" -ForegroundColor Green
            
            # 显示失败的文件
            if ($resultJson.fail_count -gt 0) {
                Write-Host "  失败的文件:" -ForegroundColor Yellow
                foreach ($file in $resultJson.files) {
                    if (-not $file.success) {
                        Write-Host "    - $($file.gz_file): $($file.error)" -ForegroundColor Red
                    }
                }
            }
            
            return $true
        } else {
            Write-Host "  解压失败: $($resultJson.message)" -ForegroundColor Red
            return $false
        }
    } catch {
        Write-Host "  警告: Python脚本执行失败: $_" -ForegroundColor Yellow
        return $false
    }
}

# 主程序
Write-Host "=== HarmonyOS 模拟器崩溃日志分析 ===" -ForegroundColor Cyan
Write-Host ""

# 获取实例路径
if (-not $InstancePath) {
    if ($AutoFind) {
        $InstancePath = Find-EmulatorInstance
        if (-not $InstancePath) {
            exit 1
        }
    } else {
        Write-Host "错误: 请提供实例路径或使用 -AutoFind 参数" -ForegroundColor Red
        exit 1
    }
}

# 验证实例路径
if (-not (Test-InstancePath -Path $InstancePath)) {
    exit 1
}

# 规范化路径
$InstancePath = Normalize-Path -Path $InstancePath

# 查找崩溃日志目录
$crashLogDir = Find-CrashLogDir -InstancePath $InstancePath
if (-not $crashLogDir) {
    exit 1
}

# 查找崩溃报告文件
$crashReportFile = Find-CrashReportFile -CrashLogDir $crashLogDir -CrashReportPath $CrashReportPath
if (-not $crashReportFile) {
    exit 1
}

# 创建解压目录
$extractDir = Join-Path $crashLogDir "crash_report_extracted"
Write-Host ""
Write-Host "创建解压目录: $extractDir" -ForegroundColor Yellow

if (Test-Path $extractDir) {
    Write-Host "删除旧的解压目录..." -ForegroundColor DarkGray
    Remove-Item -Path $extractDir -Recurse -Force
}

New-Item -Path $extractDir -ItemType Directory | Out-Null

# 解压崩溃报告
Write-Host ""
Write-Host "正在解压崩溃报告..." -ForegroundColor Yellow
try {
    Expand-Archive -Path $crashReportFile -DestinationPath $extractDir -Force
    Write-Host "解压完成" -ForegroundColor Green
} catch {
    Write-Host "错误: 解压失败: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "调试信息:" -ForegroundColor Yellow
    Write-Host "  请检查文件是否损坏" -ForegroundColor White
    Write-Host "  请检查是否有足够的磁盘空间" -ForegroundColor White
    Write-Host "  请检查是否有写入权限" -ForegroundColor White
    exit 1
}

# 解压hilog_tmp_xxx文件夹中的.gz日志
$hilogDirs = Get-ChildItem -Path $extractDir -Filter "hilog_tmp_*" -Directory -ErrorAction SilentlyContinue
if ($hilogDirs) {
    Write-Host ""
    Write-Host "正在解压hilog日志..." -ForegroundColor Yellow

    foreach ($dir in $hilogDirs) {
        $hilogDir = $dir.FullName
        Write-Host "  解压目录: $($dir.Name)" -ForegroundColor Cyan
        
        Extract-GzFiles -Directory $hilogDir
    }
    
    Write-Host "hilog日志解压完成" -ForegroundColor Green
}

# 显示崩溃摘要信息
Write-Host ""
Write-Host "=== 崩溃摘要 ===" -ForegroundColor Yellow

if (Test-Path (Join-Path $extractDir "details.txt")) {
    Write-Host ""
    Write-Host "--- 崩溃详情 ---" -ForegroundColor Cyan
    Get-Content (Join-Path $extractDir "details.txt")
}

if (Test-Path (Join-Path $extractDir "reproductionsteps.txt")) {
    Write-Host ""
    Write-Host "--- 崩溃前的操作 ---" -ForegroundColor Cyan
    Get-Content (Join-Path $extractDir "reproductionsteps.txt")
}

# 显示文件列表
Write-Host ""
Write-Host "=== 解压后的文件 ===" -ForegroundColor Yellow
Get-ChildItem -Path $extractDir -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    $relativePath = $_.FullName.Substring($extractDir.Length + 1)
    $size = if ($_.PSIsContainer) { "<DIR>" } else { "{0:N2} KB" -f ($_.Length / 1KB) }
    Write-Host "  $relativePath ($size)"
}

# 生成分析报告
$reportFile = Join-Path $crashLogDir "crash_analysis_report.txt"
Write-Host ""
Write-Host "=== 生成分析报告 ===" -ForegroundColor Yellow

$reportContent = "HarmonyOS模拟器崩溃日志分析报告"
$reportContent += "`n====================================`n`n"
$reportContent += "分析时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"
$reportContent += "实例路径: $InstancePath`n"
$reportContent += "崩溃报告: $(Split-Path $crashReportFile -Leaf)`n"
$reportContent += "解压目录: $extractDir`n"
$reportContent += "`n---`n`n"

$reportContent | Out-File -FilePath $reportFile -Encoding UTF8

if (Test-Path (Join-Path $extractDir "details.txt")) {
    $reportContent += "[崩溃详情]`n`n"
    $reportContent += Get-Content (Join-Path $extractDir "details.txt") -Raw
    $reportContent += "`n`n"
}

if (Test-Path (Join-Path $extractDir "reproductionsteps.txt")) {
    $reportContent += "[崩溃前的操作]`n`n"
    $reportContent += Get-Content (Join-Path $extractDir "reproductionsteps.txt") -Raw
    $reportContent += "`n`n"
}

if (Test-Path (Join-Path $extractDir "Emulator.log")) {
    $reportContent = Get-Content $reportFile -Raw
    $reportContent += "[模拟器日志错误]`n`n"
    $errors = Get-Content (Join-Path $extractDir "Emulator.log") | Select-String -Pattern "Error|error|ERROR" -ErrorAction SilentlyContinue
    if ($errors) {
        $reportContent += $errors | Out-String
    } else {
        $reportContent += "未找到错误信息`n"
    }
    $reportContent += "`n`n"
}

if (Test-Path (Join-Path $extractDir "kernel.log")) {
    $reportContent = Get-Content $reportFile -Raw
    $reportContent += "[内核日志错误]`n`n"
    $errors = Get-Content (Join-Path $extractDir "kernel.log") | Select-String -Pattern "Error|error|ERROR" -ErrorAction SilentlyContinue
    if ($errors) {
        $reportContent += $errors | Out-String
    } else {
        $reportContent += "未找到错误信息`n"
    }
    $reportContent += "`n`n"
}

$reportContent | Out-File -FilePath $reportFile -Encoding UTF8

Write-Host "分析报告已保存到: $reportFile" -ForegroundColor Green

Write-Host ""
Write-Host "分析完成！" -ForegroundColor Green
Write-Host "解压目录: $extractDir" -ForegroundColor Cyan
Write-Host "分析报告: $reportFile" -ForegroundColor Cyan
