#!/bin/bash

# Configuration
BOT_TOKEN=${BOT_TOKEN_ENV}
CHAT_ID=${CHAT_ID_ENV}
TEMP_VIDEO_FILE="downloaded_video.mp4"
SPLIT_DIR="video_parts"
NUM_PARTS=5
MAX_SIZE=$((48 * 1024 * 1024))  # 48MB Telegram file size limit
LOG_FILE="bot.log"

# Redirect logs to a file
exec > >(tee -i "$LOG_FILE")
exec 2>&1

# Function to send a message to Telegram
send_telegram_message() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d "chat_id=$CHAT_ID" \
        -d "text=$message" \
        -d "parse_mode=HTML"
}

# Function to update a Telegram message
update_telegram_message() {
    local message_id="$1"
    local new_text="$2"
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" \
        -d "chat_id=$CHAT_ID" \
        -d "message_id=$message_id" \
        -d "text=$new_text" \
        -d "parse_mode=HTML" > /dev/null
}

# Cleanup temporary files
cleanup() {
    rm -rf "$SPLIT_DIR" "$TEMP_VIDEO_FILE"
}

# Download file parts
download_file_parts() {
    local url="$1"
    local message_id="$2"
    local estimated_part_size=$((MAX_SIZE * NUM_PARTS))

    mkdir -p "$SPLIT_DIR"

    # Download parts in parallel
    echo "🌐 URL for download: $url"
    for i in $(seq 0 $((NUM_PARTS - 1))); do
        local start=$((i * estimated_part_size))
        local end=$(((i + 1) * estimated_part_size - 1))
        [ $i -eq $((NUM_PARTS - 1)) ] && end=""
        echo "⬇️ Downloading range: $start-$end into $SPLIT_DIR/part_$i"
        curl -L "$url" -H "Range: bytes=$start-$end" -o "$SPLIT_DIR/part_$i" || {
            echo "❌ Failed to download range $start-$end"
            return 1
        }
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

# Upload file to Telegram
upload_file() {
    local file="$1"
    local message_id="$2"
    local file_size=$(stat -c%s "$file")

    if [ $file_size -gt $MAX_SIZE ]; then
        echo "✂️ File exceeds 48MB. Splitting before upload..."
        split -b $MAX_SIZE "$file" "$SPLIT_DIR/part_"
        local total_parts=$(ls "$SPLIT_DIR"/part_* | wc -l)
        local current_part=1
        for part in "$SPLIT_DIR"/part_*; do
            update_telegram_message "$message_id" "📤 Uploading part $current_part of $total_parts..."
            curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendDocument" \
                -F "chat_id=$CHAT_ID" \
                -F "document=@$part" \
                -F "caption=Part $current_part of $total_parts" || {
                echo "❌ Failed to upload part $current_part"
                return 1
            }
            current_part=$((current_part + 1))
        done
    else
        echo "📤 Uploading video..."
        curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendDocument" \
            -F "chat_id=$CHAT_ID" \
            -F "document=@$file" || {
            echo "❌ Upload failed!"
            return 1
        }
    fi
    return 0
}

# Main Function
process_video() {
    local url="$1"

    STATUS_MSG=$(send_telegram_message "🔄 Starting video processing...")
    MESSAGE_ID=$(echo "$STATUS_MSG" | jq -r '.result.message_id')

    update_telegram_message "$MESSAGE_ID" "📥 Downloading file parts..."
    if ! download_file_parts "$url" "$MESSAGE_ID"; then
        update_telegram_message "$MESSAGE_ID" "❌ Download failed!"
        cleanup
        return 1
    fi

    if ! merge_file_parts; then
        update_telegram_message "$MESSAGE_ID" "❌ File merging failed!"
        cleanup
        return 1
    fi

    update_telegram_message "$MESSAGE_ID" "📤 Uploading file..."
    if ! upload_file "$TEMP_VIDEO_FILE" "$MESSAGE_ID"; then
        update_telegram_message "$MESSAGE_ID" "❌ Upload failed!"
        cleanup
        return 1
    fi

    update_telegram_message "$MESSAGE_ID" "✅ File uploaded successfully!"
    cleanup
}

# Start the Bot
echo "🤖 Bot is running..."
while true; do
    read -p "Enter video URL: " VIDEO_URL
    process_video "$VIDEO_URL"
done
