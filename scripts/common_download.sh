#!/bin/bash
# ฟังก์ชันร่วมสำหรับดาวน์โหลด checkpoint/LoRA
# ใช้ทั้งใน entrypoint.sh (โหลดตอน container start) และคำสั่ง ckpt/lora (โหลดระหว่างใช้งานผ่าน SSH)
# ต้อง source ไฟล์นี้ก่อนเรียกใช้ฟังก์ชัน download_asset

download_asset() {
    local url="$1"
    local dest_dir="$2"
    mkdir -p "$dest_dir"

    if [[ "$url" == *"civitai.com"* ]] || [[ "$url" == *"civitai.red"* ]]; then
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

    aria2c -x 16 -s 16 "$final_url" -d "$dest_dir"
}

_download_huggingface() {
    local url="$1"
    local dest_dir="$2"
    aria2c -x 16 -s 16 "$url" -d "$dest_dir"
}

# รองรับ: zimage (Qwen3 4B + Flux-derived VAE), anima (Qwen3 0.6B + Qwen-Image VAE)
ensure_model_arch_deps() {
    local arch="$1"

    if [ "$arch" == "zimage" ]; then
        echo "[deps] MODEL_ARCH=zimage — เช็ค/โหลด text encoder + VAE ที่จำเป็น..."
        local te_path="/workspace/forge/models/text_encoder/qwen_3_4b.safetensors"
        local vae_path="/workspace/forge/models/VAE/ae.safetensors"

        if [ ! -f "$te_path" ]; then
            aria2c -x16 -s16 \
                "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors" \
                -d /workspace/forge/models/text_encoder -o qwen_3_4b.safetensors
        else
            echo "[deps] text encoder มีอยู่แล้ว ข้ามการโหลด"
        fi

        if [ ! -f "$vae_path" ]; then
            aria2c -x16 -s16 \
                "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/vae/ae.safetensors" \
                -d /workspace/forge/models/VAE -o ae.safetensors
        else
            echo "[deps] VAE มีอยู่แล้ว ข้ามการโหลด"
        fi

    elif [ "$arch" == "anima" ]; then
        echo "[deps] MODEL_ARCH=anima — เช็ค/โหลด text encoder + VAE ที่จำเป็น..."
        local te_path="/workspace/forge/models/text_encoder/qwen_3_06b_base.safetensors"
        local vae_path="/workspace/forge/models/VAE/qwen_image_vae.safetensors"

        if [ ! -f "$te_path" ]; then
            aria2c -x16 -s16 \
                "https://huggingface.co/circlestone-labs/Anima/resolve/main/split_files/text_encoders/qwen_3_06b_base.safetensors" \
                -d /workspace/forge/models/text_encoder -o qwen_3_06b_base.safetensors
        else
            echo "[deps] text encoder มีอยู่แล้ว ข้ามการโหลด"
        fi

        if [ ! -f "$vae_path" ]; then
            aria2c -x16 -s16 \
                "https://huggingface.co/circlestone-labs/Anima/resolve/main/split_files/vae/qwen_image_vae.safetensors" \
                -d /workspace/forge/models/VAE -o qwen_image_vae.safetensors
        else
            echo "[deps] VAE มีอยู่แล้ว ข้ามการโหลด"
        fi

    elif [ -n "$arch" ]; then
        echo "[deps]
