#!/bin/bash

# AcaDome Video Processor (Improved)
# Handles: Duration check, optional splitting (>20m), multi-bitrate HLS,
# AES-128 encryption, and creates a high-quality compressed archive.
#
# Quality Philosophy:
# - CRF 23 for 720p (visually lossless for most content)
# - CRF 25 for 480p (excellent for mobile screens)
# - Archive: CRF 22 (preserves maximum quality for long-term storage)
# - x264 "slow" preset for better compression ratio at same quality

INPUT_VIDEO=$1
OUTPUT_NAME=$2
SEGMENT_TIME=1200 # 20 minutes

if [ -z "$INPUT_VIDEO" ] || [ -z "$OUTPUT_NAME" ]; then
    echo "Usage: ./process.sh <input_video> <output_name>"
    exit 1
fi

MODE=${MODE:-hls} # Default to hls mode
echo "  Mode:       $MODE"

mkdir -p output/"$OUTPUT_NAME"
cd output/"$OUTPUT_NAME"

# ───────────────────────────────────────────────
# 1. Get Metadata
# ───────────────────────────────────────────────
DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "../../$INPUT_VIDEO")
WIDTH=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 "../../$INPUT_VIDEO")
HEIGHT=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 "../../$INPUT_VIDEO")
FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "../../$INPUT_VIDEO" | bc -l | xargs printf "%.0f")
ORIGINAL_SIZE=$(stat -c%s "../../$INPUT_VIDEO" 2>/dev/null || stat -f%z "../../$INPUT_VIDEO" 2>/dev/null)

echo "═══════════════════════════════════════"
echo "  AcaDome Video Encoder v2.0"
echo "═══════════════════════════════════════"
echo "  Duration:   ${DURATION}s"
echo "  Resolution: ${WIDTH}x${HEIGHT}"
echo "  FPS:        ${FPS}"
echo "  Size:       ${ORIGINAL_SIZE} bytes"
echo "═══════════════════════════════════════"

# Calculate GOP size (2 seconds worth of frames, capped at 96)
GOP=$((FPS * 2))
if [ "$GOP" -gt 96 ]; then GOP=96; fi
if [ "$GOP" -lt 24 ]; then GOP=48; fi

# ───────────────────────────────────────────────
# 2. Generate Encryption Key
# ───────────────────────────────────────────────
openssl rand 16 > video.key
echo "video.key" > key_info
echo "video.key" >> key_info
echo "Key generated."

# ───────────────────────────────────────────────
# 3. Splitting Logic (only for long videos)
# ───────────────────────────────────────────────
MAX_SEGMENT_SECONDS=1200

if (( $(echo "$DURATION > $MAX_SEGMENT_SECONDS" | bc -l) )); then
    echo "Video is long ($DURATION s). Splitting into 20-minute parts..."
    ffmpeg -i "../../$INPUT_VIDEO" -c copy -map 0 -segment_time "$MAX_SEGMENT_SECONDS" -f segment "part_%03d.mp4"
else
    echo "Video within 20 minutes. Direct processing."
    cp "../../$INPUT_VIDEO" "part_000.mp4"
fi

# ───────────────────────────────────────────────
# 4. Determine encodable resolutions (Don't upscale)
# ───────────────────────────────────────────────
HAS_720P=false
HAS_480P=false

if [ "$HEIGHT" -ge 720 ]; then HAS_720P=true; fi
if [ "$HEIGHT" -ge 480 ]; then HAS_480P=true; fi
if [ "$HAS_480P" = false ] && [ "$HAS_720P" = false ]; then HAS_480P=true; fi

# ───────────────────────────────────────────────
# 5. Encoding Loop
# ───────────────────────────────────────────────
if [ "$MODE" = "compress" ]; then
    echo "Skipping HLS encoding (Compress mode active)."
else
    echo "Starting Multi-Bitrate HLS Encoding (AES-128)..."

    for part in part_*.mp4; do
        PART_NUM=${part#part_}
        PART_NUM=${PART_NUM%.mp4}

        if [ "$HAS_720P" = true ]; then
            echo "Encoding Part $PART_NUM (720p, CRF 23)..."
            ffmpeg -i "$part" \
                -c:v libx264 -crf 23 -maxrate 2M -bufsize 4M \
                -preset slow -tune film -profile:v high -level 4.1 \
                -filter:v "scale=-2:720,format=yuv420p" \
                -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 \
                -c:a aac -b:a 128k -ac 2 -ar 44100 \
                -movflags +faststart \
                -hls_time 8 -hls_playlist_type vod \
                -hls_key_info_file key_info \
                -hls_segment_filename "720p_${PART_NUM}_%03d.ts" "720p_${PART_NUM}.m3u8"
        fi

        if [ "$HAS_480P" = true ]; then
            echo "Encoding Part $PART_NUM (480p, CRF 25)..."
            ffmpeg -i "$part" \
                -c:v libx264 -crf 25 -maxrate 1M -bufsize 2M \
                -preset slow -tune film -profile:v main -level 3.1 \
                -filter:v "scale=-2:480,format=yuv420p" \
                -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 \
                -c:a aac -b:a 96k -ac 2 -ar 44100 \
                -movflags +faststart \
                -hls_time 8 -hls_playlist_type vod \
                -hls_key_info_file key_info \
                -hls_segment_filename "480p_${PART_NUM}_%03d.ts" "480p_${PART_NUM}.m3u8"
        fi
    done
fi

# ───────────────────────────────────────────────
# 6. Stitch Playlists (merge split parts)
# ───────────────────────────────────────────────
function stitch_playlists() {
    RES=$1
    FINAL_FILE="${RES}.m3u8"
    if [ ! -f "${RES}_000.m3u8" ]; then return; fi

    echo "#EXTM3U" > "$FINAL_FILE"
    echo "#EXT-X-VERSION:3" >> "$FINAL_FILE"
    echo "#EXT-X-TARGETDURATION:10" >> "$FINAL_FILE"
    echo "#EXT-X-MEDIA-SEQUENCE:0" >> "$FINAL_FILE"
    echo "#EXT-X-PLAYLIST-TYPE:VOD" >> "$FINAL_FILE"
    echo "#EXT-X-KEY:METHOD=AES-128,URI=\"video.key\"" >> "$FINAL_FILE"

    for p in ${RES}_*.m3u8; do
        sed -n '/#EXTINF/,$p' "$p" | grep -v "#EXT-X-ENDLIST" >> "$FINAL_FILE"
    done
    echo "#EXT-X-ENDLIST" >> "$FINAL_FILE"
}

if [ "$MODE" != "compress" ]; then
    if [ "$HAS_720P" = true ]; then stitch_playlists "720p"; fi
    if [ "$HAS_480P" = true ]; then stitch_playlists "480p"; fi
fi

# ───────────────────────────────────────────────
# 7. Master Playlist
# ───────────────────────────────────────────────
if [ "$MODE" != "compress" ]; then
    echo "#EXTM3U" > master.m3u8
    echo "#EXT-X-VERSION:3" >> master.m3u8

    if [ "$HAS_720P" = true ]; then
        echo "#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,NAME=\"720p\"" >> master.m3u8
        echo "720p.m3u8" >> master.m3u8
    fi

    if [ "$HAS_480P" = true ]; then
        echo "#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=842x480,NAME=\"480p\"" >> master.m3u8
        echo "480p.m3u8" >> master.m3u8
    fi
fi

# ───────────────────────────────────────────────
# 8. Generate thumbnail (poster frame at 2 seconds)
# ───────────────────────────────────────────────
echo "Generating thumbnail..."
ffmpeg -i "../../$INPUT_VIDEO" -ss 2 -vframes 1 \
    -filter:v "scale=-2:480" -q:v 3 \
    thumbnail.jpg 2>/dev/null || echo "Thumbnail generation skipped."

THUMB_SIZE=$(stat -c%s thumbnail.jpg 2>/dev/null || echo "0")

# ───────────────────────────────────────────────
# 9. Compressed Archive (High Quality CRF 22)
# ───────────────────────────────────────────────
echo "Creating compressed archive (CRF 22, high quality)..."
mkdir -p archive
ffmpeg -i "../../$INPUT_VIDEO" \
    -c:v libx264 -crf 22 -maxrate 2.5M -bufsize 5M \
    -preset slow -tune film -profile:v high -level 4.1 \
    -filter:v "scale=-2:'min(720,ih)',format=yuv420p" \
    -c:a aac -b:a 128k -ac 2 -ar 44100 \
    -movflags +faststart \
    archive/compressed.mp4

ARCHIVE_SIZE=$(stat -c%s archive/compressed.mp4 2>/dev/null || stat -f%z archive/compressed.mp4 2>/dev/null)
echo "Archive: $ARCHIVE_SIZE bytes (Original: $ORIGINAL_SIZE bytes)"
echo "Compression Ratio: $(echo "scale=1; $ORIGINAL_SIZE / $ARCHIVE_SIZE" | bc)x"

# ───────────────────────────────────────────────
# 10. Generate metadata JSON (for DB and CDN)
# ───────────────────────────────────────────────
echo "Generating metadata..."
SEGMENT_COUNT=$(ls -1 *.ts 2>/dev/null | wc -l)
HLS_SIZE=$(find . -maxdepth 1 \( -name "*.ts" -o -name "*.m3u8" -o -name "*.key" \) -exec stat -c%s {} + 2>/dev/null | awk '{s+=$1} END {print s+0}')

cat > metadata.json <<EOF
{
    "duration": $DURATION,
    "width": $WIDTH,
    "height": $HEIGHT,
    "fps": $FPS,
    "original_size": $ORIGINAL_SIZE,
    "hls_size": $HLS_SIZE,
    "archive_size": $ARCHIVE_SIZE,
    "thumbnail_size": $THUMB_SIZE,
    "segment_count": $SEGMENT_COUNT,
    "variants": [$([ "$HAS_720P" = true ] && echo '"720p"')$([ "$HAS_720P" = true ] && [ "$HAS_480P" = true ] && echo ', ')$([ "$HAS_480P" = true ] && echo '"480p"')],
    "encoded_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

# ───────────────────────────────────────────────
# 11. Cleanup intermediate files
# ───────────────────────────────────────────────
echo "Cleaning up..."
rm -f part_*.mp4
rm -f *_*.m3u8
rm -f key_info

# ───────────────────────────────────────────────
# 12. Summary
# ───────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════"
echo "  Encoding Complete!"
echo "═══════════════════════════════════════"
echo "  HLS:     $HLS_SIZE bytes ($SEGMENT_COUNT segments)"
echo "  Archive: $ARCHIVE_SIZE bytes"
echo "  Thumb:   $THUMB_SIZE bytes"
echo "  Savings: $(echo "scale=1; (1 - ($HLS_SIZE + $ARCHIVE_SIZE) / $ORIGINAL_SIZE) * 100" | bc)%"
echo "═══════════════════════════════════════"

echo "ARCHIVE_SIZE=$ARCHIVE_SIZE"
echo "HLS_SIZE=$HLS_SIZE"
echo "THUMB_SIZE=$THUMB_SIZE"
