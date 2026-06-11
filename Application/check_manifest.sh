#!/bin/bash
# DASH Manifest诊断工具
# 用法: ./check_manifest.sh <session_id>

SESSION_ID=$1
PORT=41841  # 从日志中获取实际端口

if [ -z "$SESSION_ID" ]; then
    echo "用法: $0 <session_id>"
    echo "示例: $0 s1781102236604_1"
    exit 1
fi

echo "=== 获取DASH Manifest ==="
hdc shell "curl -s http://127.0.0.1:${PORT}/session/${SESSION_ID}/manifest.mpd"

echo ""
echo ""
echo "=== 分析结果 ==="
MANIFEST=$(hdc shell "curl -s http://127.0.0.1:${PORT}/session/${SESSION_ID}/manifest.mpd")

# 检查是否使用SegmentList
if echo "$MANIFEST" | grep -q "<SegmentList"; then
    echo "✅ 使用SegmentList"

    # 统计segment数量
    VIDEO_SEGMENTS=$(echo "$MANIFEST" | grep -A 1000 'contentType="video"' | grep "<SegmentURL" | wc -l)
    AUDIO_SEGMENTS=$(echo "$MANIFEST" | grep -A 1000 'contentType="audio"' | grep "<SegmentURL" | wc -l)

    echo "   视频segments: $VIDEO_SEGMENTS"
    echo "   音频segments: $AUDIO_SEGMENTS"

    # 检查前3个segment的duration
    echo ""
    echo "前3个视频segment:"
    echo "$MANIFEST" | grep -A 1000 'contentType="video"' | grep "<SegmentURL" | head -3

elif echo "$MANIFEST" | grep -q "<SegmentBase"; then
    echo "⚠️  使用SegmentBase (可能有问题)"
else
    echo "❌ 未知的segment模式"
fi

# 检查总时长
DURATION=$(echo "$MANIFEST" | grep "mediaPresentationDuration" | sed 's/.*PT\([0-9.]*\)S.*/\1/')
echo ""
echo "总时长: ${DURATION}s"
