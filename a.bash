#!/bin/bash

# Configuration
BOT_TOKEN=${BOT_TOKEN_ENV}
if [ -z "$BOT_TOKEN" ]; then
    log "ERROR" "❌ BOT_TOKEN is not set. Exiting..."
    exit 1
fi

TEMP_VIDEO_FILE="downloaded_video.mp4"
SPLIT_DIR="video_parts"
NUM_PARTS=5
MAX_SIZE=$((48 * 1024 * 1024))  # 48MB Telegram file size limit
LOG_FILE="bot.log"
ENABLE_STREAMABLE_CHECK=true  # Optional streamable feature

# Redirect logs to a file
exec > >(tee -i "$LOG_FILE")
exec 2>&1

# Logging function
log() {
    local level=$1
    local message=$2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$LOG_FILE"
}

# Function to send a message to Telegram
send_telegram_message() {
    local chat_id="$1"
    local message="$2"
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d "chat_id=$chat_id" \
        -d "text=$message" \
        -d "parse_mode=HTML"
}

# Function to update a Telegram message
update_telegram_message() {
    local chat_id="$1"
    local message_id="$2"
    local new_text="$3"
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" \
        -d "chat_id=$chat_id" \
        -d "message_id=$message_id" \
        -d "text=$new_text" \
        -d "parse_mode=HTML" > /dev/null
}

# Check dependencies
check_dependencies() {
    local dependencies=("curl" "ffmpeg" "ffprobe" "jq")
    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log "ERROR" "❌ $dep is not installed. Please install it and try again."
            exit 1
        fi
    done
}

# Cleanup temporary files
cleanup() {
    rm -rf "$SPLIT_DIR" "$TEMP_VIDEO_FILE"
    log "INFO" "✅ Cleaned up temporary files."
}

# Check if the video is streamable (after full download)
check_streamable() {
    local file="$1"
    local chat_id="$2"

    if [ "$ENABLE_STREAMABLE_CHECK" = true ]; then
        log "INFO" "🔍 Checking if the video is streamable..."

        # Check if the video is encoded with H.264
        ffprobe_output=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1 "$file" 2>&1)
        if [[ "$ffprobe_output" != *"h264"* ]]; then
            log "WARNING" "⚠️ Video is not encoded with H.264. Re-encoding..."
            reencoded_file="reencoded_$TEMP_VIDEO_FILE"
            ffmpeg -i "$file" -vcodec libx264 -acodec aac -movflags +faststart -force_key_frames "expr:gte(t,n_forced*1)" "$reencoded_file" -y
            if [ -f "$reencoded_file" ]; then
                mv "$reencoded_file" "$file"
                log "INFO" "✅ Video successfully re-encoded to H.264 with a keyframe at the start."
            else
                log "ERROR" "❌ Re-encoding failed."
                send_telegram_message "$chat_id" "❌ Failed to re-encode the video to a streamable format."
                return 1
            fi
        else
            log "INFO" "✅ Video is encoded with H.264. Ensuring MOOV atom placement and keyframe at the start..."

            # Ensure MOOV atom is at the beginning and force a keyframe at the start
            streamable_file="streamable_$TEMP_VIDEO_FILE"
            ffmpeg -i "$file" -movflags +faststart -force_key_frames "expr:gte(t,n_forced*1)" -c copy "$streamable_file" -y
            if [ -f "$streamable_file" ]; then
                mv "$streamable_file" "$file"
                log "INFO" "✅ MOOV atom moved to the beginning, and a keyframe is forced at the start."
            else
                log "ERROR" "❌ Failed to ensure streamable format."
                send_telegram_message "$chat_id" "❌ Failed to ensure the video is streamable."
                return 1
            fi
        fi
    else
        log "INFO" "⚠️ Streamable check is disabled."
    fi
    return 0
}

# Compress video to fit within the 48MB limit
compress_video() {
    local file="$1"
    local compressed_file="compressed_$file"
    log "INFO" "🔧 Attempting to compress video to fit within 48MB..."

    # Use a more robust ffmpeg command to handle audio and video streams
    ffmpeg -i "$file" -vcodec libx264 -crf 28 -preset fast -acodec aac -b:a 128k -movflags +faststart "$compressed_file" -y
    if [ $? -eq 0 ] && [ -f "$compressed_file" ]; then
        mv "$compressed_file" "$file"
        log "INFO" "✅ Video compressed successfully."
        return 0
    else
        log "ERROR" "❌ Video compression failed."
        return 1
    fi
}

# Convert bytes to human-readable size
human_readable_size() {
    local size=$1
    if [ "$size" -ge $((1024 * 1024 * 1024)) ]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $size / (1024 * 1024 * 1024)}") GB"
    elif [ "$size" -ge $((1024 * 1024)) ]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $size / (1024 * 1024)}") MB"
    else
        echo "$(awk "BEGIN {printf \"%.2f\", $size / 1024}") KB"
    fi
}

# Download file parts with progress
download_file_parts() {
    local url="$1"
    local chat_id="$2"
    local message_id="$3"

    content_disposition=$(curl -sI --connect-timeout 15 "$url" | grep -i "Content-Disposition" | awk -F'filename=' '{print $2}' | tr -d '\r\n"')
    file_name=$(basename "$content_disposition")
    [ -z "$file_name" ] && file_name=$(basename "$url")
    TEMP_VIDEO_FILE="$file_name"

    total_size=$(curl -sI --connect-timeout 15 "$url" | grep -i Content-Length | awk '{print $2}' | tr -d '\r')

    if [ -z "$total_size" ]; then
        send_telegram_message "$chat_id" "❌ Unable to determine file size. Progress tracking will be disabled."
        total_size=-1  # Set to -1 if size is not retrievable
    else
        readable_size=$(human_readable_size "$total_size")
        send_telegram_message "$chat_id" "🌐 Total file size: $readable_size. Starting download of $file_name..."
    fi

    mkdir -p "$SPLIT_DIR"
    log "INFO" "📁 Created directory for video parts: $SPLIT_DIR"

    for i in $(seq 0 $((NUM_PARTS - 1))); do
        local start=$((i * total_size / NUM_PARTS))
        local end=$(((i + 1) * total_size / NUM_PARTS - 1))
        [ $i -eq $((NUM_PARTS - 1)) ] && end=""

        log "INFO" "⬇️ Downloading range: $start-$end into $SPLIT_DIR/part_$i"

        temp_log="curl_log_$i.txt"  # Temporary log for curl output
        curl -L --connect-timeout 15 "$url" -H "Range: bytes=$start-$end" -o "$SPLIT_DIR/part_$i" --write-out "%{size_download}" 2>/dev/null > "$temp_log"
        size_downloaded=$(cat "$temp_log")
        rm -f "$temp_log"

        if [ -z "$size_downloaded" ] || [ "$size_downloaded" -eq 0 ]; then
            log "ERROR" "❌ Error downloading range $start-$end of $file_name."
            send_telegram_message "$chat_id" "❌ Error downloading range $start-$end of $file_name."
            return 1
        fi

        if [ "$total_size" -ne -1 ]; then
            progress=$(( (start + size_downloaded) * 100 / total_size ))
            update_telegram_message "$chat_id" "$message_id" "📥 Downloading... ${progress}% completed."
        else
            update_telegram_message "$chat_id" "$message_id" "📥 Downloading part $((i + 1)) of $NUM_PARTS..."
        fi
    done
    log "INFO" "✅ All parts downloaded successfully."
    return 0
}

# Merge file parts
merge_file_parts() {
    log "INFO" "🔗 Merging file parts..."
    cat "$SPLIT_DIR"/part_* > "$TEMP_VIDEO_FILE"
    if [ ! -f "$TEMP_VIDEO_FILE" ]; then
        log "ERROR" "❌ Merging failed!"
        return 1
    fi
    log "INFO" "✅ File successfully merged: $TEMP_VIDEO_FILE"
    return 0
}

# Upload file with the file name in the caption
upload_file() {
    local file="$1"
    local chat_id="$2"
    local message_id="$3"
    local file_name=$(basename "$file")
    local file_size=$(stat -c%s "$file")

    if [ $file_size -gt $MAX_SIZE ]; then
        log "INFO" "✂️ File exceeds 48MB. Attempting to compress..."
        if ! compress_video "$file"; then
            log "INFO" "⚠️ Compression failed. Splitting file..."
            split -b $MAX_SIZE "$file" "$SPLIT_DIR/part_"
            local total_parts=$(ls "$SPLIT_DIR"/part_* | wc -l)
            local current_part=1
            for part in "$SPLIT_DIR"/part_*; do
                progress=$((current_part * 100 / total_parts))
                update_telegram_message "$chat_id" "$message_id" "📤 Uploading part $current_part of $total_parts (${progress}%)..."
                curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendDocument" \
                    -F "chat_id=$chat_id" \
                    -F "document=@$part" \
                    -F "caption=Part $current_part of $total_parts: $file_name" || {
                    log "ERROR" "❌ Failed to upload part $current_part"
                    return 1
                }
                current_part=$((current_part + 1))
            done
        else
            # Retry upload after compression
            file_size=$(stat -c%s "$file")
            if [ $file_size -le $MAX_SIZE ]; then
                log "INFO" "📤 Uploading compressed video..."
                curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendVideo" \
                    -F "chat_id=$chat_id" \
                    -F "video=@$file" \
                    -F "caption=$file_name" || {
                    log "ERROR" "❌ Upload failed!"
                    return 1
                }
            else
                log "ERROR" "❌ Compression did not reduce file size below 48MB."
                return 1
            fi
        fi
    else
        log "INFO" "📤 Uploading video..."
        curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendVideo" \
            -F "chat_id=$chat_id" \
            -F "video=@$file" \
            -F "caption=$file_name" || {
            log "ERROR" "❌ Upload failed!"
            return 1
        }
    fi
    log "INFO" "✅ File uploaded successfully."
    return 0
}

# Process incoming updates from Telegram
process_updates() {
    local offset=0
    while true; do
        updates=$(curl -s --connect-timeout 15 "https://api.telegram.org/bot$BOT_TOKEN/getUpdates?offset=$offset")
        if [ -z "$(echo "$updates" | jq -c '.result[]')" ]; then
            sleep 1
            continue
        fi

        for row in $(echo "$updates" | jq -c '.result[]'); do
            update_id=$(echo "$row" | jq -r '.update_id')
            chat_id=$(echo "$row" | jq -r '.message.chat.id')
            message_text=$(echo "$row" | jq -r '.message.text')

            if [[ "$message_text" =~ ^https?:// ]]; then
                STATUS_MSG=$(send_telegram_message "$chat_id" "🔄 Starting video processing...")
                MESSAGE_ID=$(echo "$STATUS_MSG" | jq -r '.result.message_id')

                # Download the video
                update_telegram_message "$chat_id" "$MESSAGE_ID" "📥 Downloading file..."
                if ! download_file_parts "$message_text" "$chat_id" "$MESSAGE_ID"; then
                    update_telegram_message "$chat_id" "$MESSAGE_ID" "❌ Download failed!"
                    cleanup
                    continue
                fi

                # Merge file parts
                if ! merge_file_parts; then
                    update_telegram_message "$chat_id" "$MESSAGE_ID" "❌ File merging failed!"
                    cleanup
                    continue
                fi

                # Check streamability and re-encode if necessary
                if ! check_streamable "$TEMP_VIDEO_FILE" "$chat_id"; then
                    update_telegram_message "$chat_id" "$MESSAGE_ID" "❌ Streamable check or re-encoding failed! Please ensure the video format is supported."
                    cleanup
                    continue
                fi

                # Upload the file
                update_telegram_message "$chat_id" "$MESSAGE_ID" "📤 Uploading file..."
                if ! upload_file "$TEMP_VIDEO_FILE" "$chat_id" "$MESSAGE_ID"; then
                    update_telegram_message "$chat_id" "$MESSAGE_ID" "❌ Upload failed!"
                    cleanup
                    continue
                fi

                update_telegram_message "$chat_id" "$MESSAGE_ID" "✅ File uploaded successfully!"
                cleanup
            else
                send_telegram_message "$chat_id" "❌ Please send a valid URL."
            fi

            offset=$((update_id + 1))
        done
        sleep 1
    done
}

# Start the Bot
log "INFO" "🤖 Bot is running..."
check_dependencies
process_updates