# AcaDome Video Encoder

A dedicated microservice for secure, adaptive video encoding using GitHub Actions.

## 🚀 Overview

This repository handles high-performance video transcoding for the AcaDome ecosystem. It converts source videos into **AES-128 Encrypted HLS streams** with adaptive bitrates (480p and 720p).

### Features
- **Adaptive Bitrate**: HLS master playlist with 480p and 720p options.
- **Anti-Download Protection**: All segments are encrypted with AES-128. Playback requires a key fetched via an authenticated AcaDome API.
- **20-Min Splitting**: Automatically splits videos longer than 20 minutes into manageable parts for stable encoding and merging.
- **Multi-Cloud Storage**: HLS segments go to **Backblaze B2** (zero egress via Bandwidth Alliance), compressed archive goes to **IDrive E2**, and thumbnails/metadata stay in **Cloudflare R2**.
- **CDN Warming**: Webhook notifies the main app, which immediately warms the first 30 segments on Cloudflare Edge.
- **Quality-Focused Compression**: CRF 23 (720p) / CRF 25 (480p) with x264 "slow" preset for maximum quality at minimum file size.

## 📐 Storage Architecture

| File Type | Provider | Cache-Control | Reason |
|-----------|----------|---------------|--------|
| `.ts` segments | B2 | `immutable, 1yr` | Zero egress via Bandwidth Alliance |
| `.m3u8` playlists | B2 | `1hr browser, 24hr edge` | Playlist updates more often |
| `video.key` | B2 | `immutable, 1yr` | Encryption key, won't change |
| `compressed.mp4` | E2 | `immutable, 1yr` | Long-term archive, cheap storage |
| `thumbnail.jpg` | R2 | `immutable, 1yr` | Hot file, zero egress, instant preview |
| `metadata.json` | R2 | `1hr` | Hot file, may update |

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
    "video_url": "https://assets.acadome.dev/users/{uuid}/videos/{hash}/original.mp4",
    "file_name": "unique_video_id",
    "user_id": "user_uuid",
    "callback_url": "https://acadome.dev/api/webhooks/video"
  }
}
```

### Required Secrets
The following secrets must be configured in your GitHub Repository Settings:

| Secret | Description |
|--------|-------------|
| `R2_ACCESS_KEY_ID` | Cloudflare R2 Access Key |
| `R2_SECRET_ACCESS_KEY` | Cloudflare R2 Secret Key |
| `R2_ENDPOINT` | Cloudflare R2 S3 API Endpoint |
| `R2_BUCKET_NAME` | Target R2 bucket name |
| `B2_ACCESS_KEY_ID` | Backblaze B2 Access Key |
| `B2_SECRET_ACCESS_KEY` | Backblaze B2 Secret Key |
| `B2_ENDPOINT` | Backblaze B2 S3 API Endpoint |
| `B2_BUCKET_NAME` | Target B2 bucket name |
| `E2_ACCESS_KEY_ID` | IDrive E2 Access Key |
| `E2_SECRET_ACCESS_KEY` | IDrive E2 Secret Key |
| `E2_ENDPOINT` | IDrive E2 S3 API Endpoint |
| `E2_BUCKET_NAME` | Target E2 bucket name |

## 🛡️ Playing Encrypted Videos
1. The frontend player requests the `.m3u8` playlist.
2. The playlist contains a reference to `video.key`.
3. The player must be configured to fetch this key from your AcaDome Backend (e.g., `/api/video/key?id=...`).
4. Your backend verifies the user's subscription/access and returns the 16-byte key.

## 📜 License
Privately owned by AcaDome.
