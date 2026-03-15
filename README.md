# AcaDome Video Encoder

A dedicated microservice for secure, adaptive video encoding using GitHub Actions.

## 🚀 Overview

This repository handles high-performance video transcoding for the AcaDome ecosystem. It converts source videos into **AES-128 Encrypted HLS streams** with adaptive bitrates (480p and 720p).

### Features
- **Adaptive Bitrate**: HLS master playlist with 480p and 720p options.
- **Anti-Download Protection**: All segments are encrypted with AES-128. Playback requires a key fetched via an authenticated AcaDome API.
- **20-Min Splitting**: Automatically splits videos longer than 20 minutes into manageable parts for stable encoding and merging.
- **R2 Integration**: Ready to sync encoded segments to Cloudflare R2.

## 🛠️ Usage

### Triggering via API
You can trigger an encoding job by sending a `repository_dispatch` event to this repository.

**Endpoint**: `POST /repos/{owner}/{repo}/dispatches`
**Event Type**: `encode_video`
**Payload**:
```json
{
  "event_type": "encode_video",
  "client_payload": {
    "video_url": "https://r2.acadome.dev/temp/source.mp4",
    "file_name": "unique_video_id",
    "callback_url": "https://acadome.dev/api/webhooks/video-complete"
  }
}
```

### Required Secrets
The following secrets must be configured in your GitHub Repository Settings:
- `R2_ACCESS_KEY_ID`: Cloudflare R2 Access Key.
- `R2_SECRET_ACCESS_KEY`: Cloudflare R2 Secret Key.
- `R2_ENDPOINT`: Cloudflare R2 S3 API Endpoint.
- `R2_BUCKET_NAME`: Target R2 bucket name.

## 🛡️ Playing Encrypted Videos
1. The frontend player requests the `.m3u8` playlist.
2. The playlist contains a reference to `video.key`.
3. The player must be configured to fetch this key from your AcaDome Backend (e.g., `/api/video/key?id=...`).
4. Your backend verifies the user's subscription/access and returns the 16-byte key.

## 📜 License
Privately owned by AcaDome.
