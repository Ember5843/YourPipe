# DASH Manifest诊断工具 (PowerShell)
# 用法: .\check_manifest.ps1 -SessionId <session_id> -Port <port>

param(
    [Parameter(Mandatory=$true)]
    [string]$SessionId,

    [Parameter(Mandatory=$false)]
    [int]$Port = 41841  # 从日志中获取实际端口
)

Write-Host "=== 获取DASH Manifest ===" -ForegroundColor Cyan
$url = "http://127.0.0.1:${Port}/session/${SessionId}/manifest.mpd"
Write-Host "URL: $url"

try {
    $manifest = hdc shell "curl -s $url"

    Write-Host "`n=== Manifest内容 (前50行) ===" -ForegroundColor Cyan
    $manifest -split "`n" | Select-Object -First 50

    Write-Host "`n=== 分析结果 ===" -ForegroundColor Cyan

    # 检查是否使用SegmentList
    if ($manifest -match "<SegmentList") {
        Write-Host "✅ 使用SegmentList" -ForegroundColor Green

        # 统计segment数量
        $videoSegments = ([regex]::Matches($manifest, '<SegmentURL.*contentType="video"' -split '<SegmentURL')).Count - 1
        $audioSegments = ([regex]::Matches($manifest, '<SegmentURL.*contentType="audio"' -split '<SegmentURL')).Count - 1

        Write-Host "   视频segments: $videoSegments"
        Write-Host "   音频segments: $audioSegments"

        # 显示前3个video segment
        Write-Host "`n前3个视频segments:" -ForegroundColor Yellow
        $manifest -split "`n" | Where-Object { $_ -match '<SegmentURL' } | Select-Object -First 3

    } elseif ($manifest -match "<SegmentBase") {
        Write-Host "⚠️  使用SegmentBase (可能有问题)" -ForegroundColor Yellow
    } else {
        Write-Host "❌ 未知的segment模式" -ForegroundColor Red
    }

    # 检查总时长
    if ($manifest -match 'mediaPresentationDuration="PT([0-9.]+)S"') {
        $duration = $matches[1]
        Write-Host "`n总时长: ${duration}s" -ForegroundColor Cyan
    }

} catch {
    Write-Host "❌ 错误: $_" -ForegroundColor Red
}

Write-Host "`n=== 使用说明 ===" -ForegroundColor Cyan
Write-Host "1. 从日志中找到session ID (例如: s1781102236604_1)"
Write-Host "2. 从日志中找到端口 (例如: LocalProxyServer started on port 41841)"
Write-Host "3. 运行: .\check_manifest.ps1 -SessionId s1781102236604_1 -Port 41841"
