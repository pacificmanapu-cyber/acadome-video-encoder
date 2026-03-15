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

# 1. Get Duration
DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "../../$INPUT_VIDEO")
echo "Video Duration: $DURATION seconds"

# 2. Generate Encryption Key
openssl rand 16 > video.key
echo "Key generated."

# Create key info file for FFmpeg
echo "video.key" > key_info
echo "video.key" >> key_info

# 3. Processing Logic
# If video > 20m, we split the original, encode parts, then stitch the m3u8.
# This prevents long-running single encodes and satisfies the 20m rule.

MAX_SEGMENT_SECONDS=1200 # 20 minutes

if (( $(echo "$DURATION > $MAX_SEGMENT_SECONDS" | bc -l) )); then
    echo "Video is long ($DURATION s). Splitting into 20-minute parts..."
    ffmpeg -i "../../$INPUT_VIDEO" -c copy -map 0 -segment_time "$MAX_SEGMENT_SECONDS" -f segment "part_%03d.mp4"
    PART_MODE=true
else
    echo "Video is within 20 minutes. Processing as single file."
    cp "../../$INPUT_VIDEO" "part_000.mp4"
    PART_MODE=false
fi

# 4. Encoding Loop
echo "Starting Multi-Bitrate HLS Encoding (AES-128)..."

for part in part_*.mp4; do
    PART_NUM=${part#part_}
    PART_NUM=${PART_NUM%.mp4}
    
    # 720p
    ffmpeg -i "$part" \
        -filter:v scale=-2:720 -preset fast -g 48 -sc_threshold 0 \
        -hls_time 6 -hls_playlist_type vod \
        -hls_key_info_file key_info \
        -hls_segment_filename "720p_${PART_NUM}_%03d.ts" "720p_${PART_NUM}.m3u8"

    # 480p
    ffmpeg -i "$part" \
        -filter:v scale=-2:480 -preset fast -g 48 -sc_threshold 0 \
        -hls_time 6 -hls_playlist_type vod \
        -hls_key_info_file key_info \
        -hls_segment_filename "480p_${PART_NUM}_%03d.ts" "480p_${PART_NUM}.m3u8"
done

# 5. Merge HLS Playlists (Stitching)
# For HLS, we can just concat the segment blocks in the playlist file
# We'll create a master for each resolution and then a global master.

function stitch_playlists() {
    RES=$1
    FINAL_FILE="${RES}.m3u8"
    echo "#EXTM3U" > "$FINAL_FILE"
    echo "#EXT-X-VERSION:3" >> "$FINAL_FILE"
    echo "#EXT-X-TARGETDURATION:10" >> "$FINAL_FILE"
    echo "#EXT-X-MEDIA-SEQUENCE:0" >> "$FINAL_FILE"
    echo "#EXT-X-PLAYLIST-TYPE:VOD" >> "$FINAL_FILE"
    
    # Global Key Info (since we use the same key for all parts)
    echo "#EXT-X-KEY:METHOD=AES-128,URI=\"video.key\",IV=$(openssl rand -hex 16)" >> "$FINAL_FILE"

    for p in ${RES}_*.m3u8; do
        # Extract segments (lines NOT starting with #) and append
        grep -v "^#" "$p" >> "$FINAL_FILE"
    done
    echo "#EXT-X-ENDLIST" >> "$FINAL_FILE"
}

stitch_playlists "720p"
stitch_playlists "480p"

# 6. Global Master Playlist
cat <<EOF > master.m3u8
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720,NAME="720p"
720p.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=842x480,NAME="480p"
480p.m3u8
EOF

echo "Encoding Complete. Anti-download protection (AES-128) engaged."
