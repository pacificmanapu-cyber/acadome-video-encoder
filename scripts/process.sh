#!/bin/bash

# AcaDome Video Processor
# Handles duration checking, splitting, multi-bitrate HLS encoding, and AES-128 encryption.

INPUT_VIDEO=$1
OUTPUT_NAME=$2
SEGMENT_TIME=1200 # 20 minutes

if [ -z "$INPUT_VIDEO" ] || [ -z "$OUTPUT_NAME" ]; then
    echo "Usage: ./process.sh <input_video> <output_name>"
    exit 1
fi

mkdir -p output/"$OUTPUT_NAME"
cd output/"$OUTPUT_NAME"

# 1. Get Metadata
DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "../../$INPUT_VIDEO")
WIDTH=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 "../../$INPUT_VIDEO")
HEIGHT=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 "../../$INPUT_VIDEO")

echo "Video Duration: $DURATION seconds"
echo "Video Resolution: ${WIDTH}x${HEIGHT}"

# 2. Generate Encryption Key
openssl rand 16 > video.key
echo "Key generated."

# Create key info file for FFmpeg
echo "video.key" > key_info
echo "video.key" >> key_info

# 3. Processing Logic
MAX_SEGMENT_SECONDS=1200 # 20 minutes

if (( $(echo "$DURATION > $MAX_SEGMENT_SECONDS" | bc -l) )); then
    echo "Video is long ($DURATION s). Splitting into 20-minute parts..."
    ffmpeg -i "../../$INPUT_VIDEO" -c copy -map 0 -segment_time "$MAX_SEGMENT_SECONDS" -f segment "part_%03d.mp4"
else
    echo "Video is within 20 minutes. Processing as single file."
    cp "../../$INPUT_VIDEO" "part_000.mp4"
fi

# 4. Encoding Loop
echo "Starting Optimized Multi-Bitrate HLS Encoding (AES-128)..."

# Determine which resolutions to encode (Don't upscale)
HAS_720P=false
HAS_480P=false

if [ "$HEIGHT" -ge 720 ]; then HAS_720P=true; fi
if [ "$HEIGHT" -ge 480 ]; then HAS_480P=true; fi
# If very small video, at least do 480p (or original size scale)
if [ "$HAS_480P" = false ] && [ "$HAS_720P" = false ]; then HAS_480P=true; fi

for part in part_*.mp4; do
    PART_NUM=${part#part_}
    PART_NUM=${PART_NUM%.mp4}
    
    # 720p (CRF 26 is good for mobile storage efficiency)
    if [ "$HAS_720P" = true ]; then
        echo "Encoding Part $PART_NUM (720p)..."
        ffmpeg -i "$part" \
            -c:v libx264 -crf 26 -maxrate 1.5M -bufsize 3M \
            -preset medium -filter:v scale=-2:720 -g 48 -sc_threshold 0 \
            -c:a aac -b:a 128k -ac 2 \
            -hls_time 6 -hls_playlist_type vod \
            -hls_key_info_file key_info \
            -hls_segment_filename "720p_${PART_NUM}_%03d.ts" "720p_${PART_NUM}.m3u8"
    fi

    # 480p (CRF 28 for even better storage compression)
    if [ "$HAS_480P" = true ]; then
        echo "Encoding Part $PART_NUM (480p)..."
        ffmpeg -i "$part" \
            -c:v libx264 -crf 28 -maxrate 800k -bufsize 1.6M \
            -preset medium -filter:v scale=-2:480 -g 48 -sc_threshold 0 \
            -c:a aac -b:a 96k -ac 2 \
            -hls_time 6 -hls_playlist_type vod \
            -hls_key_info_file key_info \
            -hls_segment_filename "480p_${PART_NUM}_%03d.ts" "480p_${PART_NUM}.m3u8"
    fi
done

# 5. Merge HLS Playlists (Stitching)
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
        # Keep everything from the first #EXTINF until the end of the segments
        # Remove #EXT-X-ENDLIST as we will add it once at the end
        sed -n '/#EXTINF/,$p' "$p" | grep -v "#EXT-X-ENDLIST" >> "$FINAL_FILE"
    done
    echo "#EXT-X-ENDLIST" >> "$FINAL_FILE"
}

if [ "$HAS_720P" = true ]; then stitch_playlists "720p"; fi
if [ "$HAS_480P" = true ]; then stitch_playlists "480p"; fi

# 6. Global Master Playlist
echo "#EXTM3U" > master.m3u8
echo "#EXT-X-VERSION:3" >> master.m3u8

if [ "$HAS_720P" = true ]; then
    echo "#EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=1280x720,NAME=\"720p\"" >> master.m3u8
    echo "720p.m3u8" >> master.m3u8
fi

if [ "$HAS_480P" = true ]; then
    echo "#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=842x480,NAME=\"480p\"" >> master.m3u8
    echo "480p.m3u8" >> master.m3u8
fi

echo "Optimized Encoding Complete. Storage usage minimized."
