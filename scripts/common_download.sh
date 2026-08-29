#!/bin/bash
# ฟังก์ชันร่วมสำหรับดาวน์โหลด checkpoint/LoRA
# ใช้ทั้งใน entrypoint.sh (โหลดตอน container start) และคำสั่ง ckpt/lora (โหลดระหว่างใช้งานผ่าน SSH)
# ต้อง source ไฟล์นี้ก่อนเรียกใช้ฟังก์ชัน download_asset

download_asset() {
    local url="$1"
    local dest_dir="$2"
    mkdir -p "$dest_dir"

    if [[ "$url" == *"civitai.com"* ]]; then
        _download_civitai "$url" "$dest_dir"
    elif [[ "$url" == *"huggingface.co"* ]]; then
        _download_huggingface "$url" "$dest_dir"
    else
        echo "[download] URL ไม่ใช่ CivitAI/HuggingFace — ลองโหลดตรงด้วย aria2c"
        aria2c -x 16 -s 16 "$url" -d "$dest_dir"
    fi
}

_download_civitai() {
    local url="$1"
    local dest_dir="$2"
    local version_id=""

    if [[ "$url" == *"modelVersionId="* ]]; then
        version_id="$(echo "$url" | grep -oP 'modelVersionId=\K[0-9]+')"
    else
        local model_id
        model_id="$(echo "$url" | grep -oP 'models/\K[0-9]+')"
        if [ -z "$model_id" ]; then
            echo "[download] ERROR: หา model id จาก URL ไม่ได้ — เช็ค URL: $url"
            return 1
        fi
        echo "[download] ไม่มี modelVersionId ใน URL — หาเวอร์ชันล่าสุดผ่าน CivitAI API..."
        version_id="$(curl -s "https://civitai.com/api/v1/models/${model_id}" \
            --header "Authorization: Bearer ${CIVITAI_API_KEY}" \
            | jq -r '.modelVersions[0].id')"
        if [ -z "$version_id" ] || [ "$version_id" == "null" ]; then
            echo "[download] ERROR: หา version ล่าสุดไม่สำเร็จ — เช็คว่า CIVITAI_API_KEY ใส่ถูกไหม"
            return 1
        fi
    fi

    echo "[download] CivitAI modelVersionId: ${version_id}"

    local final_url
    final_url="$(curl -s -I -L \
        --header "Authorization: Bearer ${CIVITAI_API_KEY}" \
        "https://civitai.com/api/download/models/${version_id}" \
        | grep -i "^location:" | tail -1 | sed 's/location: //I' | tr -d '\r')"

    if [ -z "$final_url" ]; then
        echo "[download] ERROR: resolve download URL ไม่สำเร็จ (โมเดลนี้อาจต้อง login ที่ CivitAI แต่ CIVITAI_API_KEY ไม่ถูกต้อง)"
        return 1
    fi

    # ห้ามใส่ Authorization header ตอนนี้ (ชนกับ signed URL ทำให้ error 400)
    aria2c -x 16 -s 16 "$final_url" -d "$dest_dir"
}

_download_huggingface() {
    local url="$1"
    local dest_dir="$2"
    aria2c -x 16 -s 16 "$url" -d "$dest_dir"
}
