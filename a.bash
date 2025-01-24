#!/bin/bash

# Configuration
BOT_TOKEN=${BOT_TOKEN_ENV}
if [ -z "$BOT_TOKEN" ]; then
    echo "❌ BOT_TOKEN is not set. Exiting..."
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

# Cleanup temporary files
cleanup() {
    rm -rf "$SPLIT_DIR" "$TEMP_VIDEO_FILE"
}

# Check if the video is streamable
check_streamable() {
    local file="$1"
    local chat_id="$2"
    
    if [ "$ENABLE_STREAMABLE_CHECK" = true ]; then
        echo "🔍 Checking if the video is streamable..."
        ffprobe_output=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1 "$file" 2>&1)
        if [[ "$ffprobe_output" != *"h264"* ]]; then
            echo "⚠️ Video is not streamable. Re-encoding..."
            reencoded_file="reencoded_$TEMP_VIDEO_FILE"
            ffmpeg -i "$file" -vcodec libx264 -acodec aac "$reencoded_file" -y
            if [ -f "$reencoded_file" ]; then
                mv "$reencoded_file" "$file"
                echo "✅ Video successfully re-encoded to streamable format."
            else
                echo "❌ Re-encoding failed."
                send_telegram_message "$chat_id" "❌ Failed to re-encode the video to a streamable format."
                return 1
            fi
        else
            echo "✅ Video is already streamable."
        fi
    else
        echo "⚠️ Streamable check is disabled."
    fi
    return 0
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

    for i in $(seq 0 $((NUM_PARTS - 1))); do
        local start=$((i * total_size / NUM_PARTS))
        local end=$(((i + 1) * total_size / NUM_PARTS - 1))
        [ $i -eq $((NUM_PARTS - 1)) ] && end=""

        echo "⬇️ Downloading range: $start-$end into $SPLIT_DIR/part_$i"

        temp_log="curl_log_$i.txt"  # Temporary log for curl output
        curl -L --connect-timeout 15 "$url" -H "Range: bytes=$start-$end" -o "$SPLIT_DIR/part_$i" --write-out "%{size_download}" 2>/dev/null > "$temp_log"
        size_downloaded=$(cat "$temp_log")
        rm -f "$temp_log"

        if [ -z "$size_downloaded" ] || [ "$size_downloaded" -eq 0 ]; then
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
    return 0
}

# Merge file parts
merge_file_parts() {
    echo "🔗 Merging file parts..."
    cat "$SPLIT_DIR"/part_* > "$TEMP_VIDEO_FILE"
    if [ ! -f "$TEMP_VIDEO_FILE" ]; then
        echo "❌ Merging failed!"
        return 1
    fi
    echo "✅ File successfully merged: $TEMP_VIDEO_FILE"
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
        echo "✂️ File exceeds 48MB. Splitting before upload..."
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
                echo "❌ Failed to upload part $current_part"
                return 1
            }
            current_part=$((current_part + 1))
        done
    else
        echo "📤 Uploading video..."
        curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendVideo" \
            -F "chat_id=$chat_id" \
            -F "video=@$file" \
            -F "caption=$file_name" || {
            echo "❌ Upload failed!"
            return 1
        }
    fi
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

                update_telegram_message "$chat_id" "$MESSAGE_ID" "📥 Downloading file parts..."
                if ! download_file_parts "$message_text" "$chat_id" "$MESSAGE_ID"; then
                    update_telegram_message "$chat_id" "$MESSAGE_ID" "❌ Download failed!"
                    cleanup
                    continue
                fi

                if ! merge_file_parts; then
                    update_telegram_message "$chat_id" "$MESSAGE_ID" "❌ File merging failed!"
                    cleanup
                    continue
                fi

                if ! check_streamable "$TEMP_VIDEO_FILE" "$chat_id"; then
                    update_telegram_message "$chat_id" "$MESSAGE_ID" "❌ Streamable check or re-encoding failed!"
                    cleanup
                    continue
                fi

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
echo "🤖 Bot is running..."
process_updates
