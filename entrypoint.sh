#!/bin/bash
set -e

cd /workspace/forge

# --- Fix บั๊ก: host/template บางที่ set PYTORCH_VERSION ไว้ล่วงหน้าแบบไม่มี +cuXXX ---
# ทำให้ launch_utils.py regex parse ไม่ผ่าน (AttributeError: 'NoneType' object has no attribute 'group')
# ดึงค่าจริงจาก torch.__version__ เสมอ แทนที่ env var เดิม
export PYTORCH_VERSION="$(python3 -c "import torch; print(torch.__version__)")"
echo "[entrypoint] PYTORCH_VERSION fixed -> ${PYTORCH_VERSION}"

# --- เช็ค CUDA พร้อมใช้งานจริงก่อนเปิด webui (fail เร็ว ดีกว่ารอ error ลึกๆ ทีหลัง) ---
python3 -c "import torch; assert torch.cuda.is_available(), 'CUDA ไม่พร้อมใช้งานบน instance นี้'"

# --- โหลด checkpoint หลักอัตโนมัติ (ถ้ามี CHECKPOINT_URL ส่งมาเป็น environment variable) ---
# ใช้เลือกได้ว่าวันนี้จะเจนรูปด้วย checkpoint ตัวไหน (Z-Image Turbo, Illustrious, ฯลฯ)
# โดยไม่ต้อง SSH เข้าไปพิมพ์เอง — ถ้าไม่ตั้งค่า จะข้ามไป (โหลดทีหลังผ่านคำสั่ง `ckpt <URL>` แทนได้)
source /workspace/scripts/common_download.sh

if [ -n "${CHECKPOINT_URL}" ]; then
    echo "[entrypoint] พบ CHECKPOINT_URL — กำลังโหลด checkpoint หลัก..."
    download_asset "${CHECKPOINT_URL}" "/workspace/forge/models/Stable-diffusion"
else
    echo "[entrypoint] ไม่พบ CHECKPOINT_URL — ยังไม่มี checkpoint ให้เลือกตอนเปิด webui"
    echo "[entrypoint] โหลดเพิ่มทีหลังผ่าน SSH ด้วยคำสั่ง: ckpt <URL>"
fi

# --- ถ้าเป็น Z-Image checkpoint (MODEL_ARCH=zimage) ต้องมี text encoder + VAE แยกเสมอ ---
# ไฟล์ 2 ตัวนี้ใช้ร่วมกันได้ทุก Z-Image checkpoint (ของ Tongyi ต้นทาง ไม่ใช่ของแต่ละคนที่ finetune)
# เช็คก่อนว่ามีอยู่แล้วไหม กันโหลดซ้ำถ้าเคยมีอยู่แล้วในเซสชันนี้
if [ "${MODEL_ARCH}" == "zimage" ]; then
    echo "[entrypoint] MODEL_ARCH=zimage — เช็ค/โหลด text encoder + VAE ที่จำเป็น..."
    TE_PATH="/workspace/forge/models/text_encoder/qwen_3_4b_fp8_scaled.safetensors"
    VAE_PATH="/workspace/forge/models/VAE/ae.safetensors"

    if [ ! -f "$TE_PATH" ]; then
        aria2c -x16 -s16 \
            "https://huggingface.co/jiangchengchengNLP/qwen3-4b-fp8-scaled/resolve/main/qwen3_4b_fp8_scaled.safetensors" \
            -d /workspace/forge/models/text_encoder -o qwen_3_4b_fp8_scaled.safetensors
    else
        echo "[entrypoint] text encoder มีอยู่แล้ว ข้ามการโหลด"
    fi

    if [ ! -f "$VAE_PATH" ]; then
        aria2c -x16 -s16 \
            "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/vae/ae.safetensors" \
            -d /workspace/forge/models/VAE -o ae.safetensors
    else
        echo "[entrypoint] VAE มีอยู่แล้ว ข้ามการโหลด"
    fi
fi

# --- เปิด ngrok อัตโนมัติ (ถ้ามี NGROK_AUTHTOKEN ส่งมาเป็น environment variable) ---
# เหตุผล: Vast.ai สุ่ม external port ทุก instance ทำให้ต้องเข้า UI ไปหา IP:Port เองทุกครั้ง
# ngrok แก้ปัญหานี้โดยให้ URL คงรูปแบบเดียวกันเสมอ (https://xxxx.ngrok-free.dev)
# หมายเหตุ: authtoken ไม่ได้ฝังอยู่ในไฟล์นี้หรือใน image เลย ต้องส่งผ่าน
#   `-e NGROK_AUTHTOKEN=...` ตอนสร้าง instance เองเท่านั้น — ถ้าไม่ตั้งค่า จะข้าม
#   ส่วนนี้ไปเฉย ๆ แล้วใช้วิธีเดิม (หา IP:Port จากหน้า Vast.ai) แทน
if [ -n "${NGROK_AUTHTOKEN}" ]; then
    echo "[entrypoint] พบ NGROK_AUTHTOKEN — กำลังเปิด public URL..."
    ngrok config add-authtoken "${NGROK_AUTHTOKEN}" >/dev/null 2>&1
    # รัน ngrok เป็น background process (ไม่ใช้ exec เพราะต้องรัน launch.py ต่อด้วย)
    nohup ngrok http 7860 --log=/workspace/ngrok.log >/dev/null 2>&1 &

    # รอ ngrok เปิด local API (http://127.0.0.1:4040) แล้วดึง public URL ออกมา
    # ลองสูงสุด 15 ครั้ง ห่างกันครั้งละ 1 วิ (กันเคส ngrok เริ่มช้ากว่าปกติ)
    NGROK_URL=""
    for i in $(seq 1 15); do
        NGROK_URL="$(curl -s http://127.0.0.1:4040/api/tunnels 2>/dev/null | jq -r '.tunnels[0].public_url' 2>/dev/null)"
        if [ -n "${NGROK_URL}" ] && [ "${NGROK_URL}" != "null" ]; then
            break
        fi
        sleep 1
    done

    if [ -n "${NGROK_URL}" ] && [ "${NGROK_URL}" != "null" ]; then
        echo "=============================================="
        echo "[entrypoint] เข้า Forge Neo ได้ที่: ${NGROK_URL}"
        echo "=============================================="
    else
        echo "[entrypoint] เตือน: เปิด ngrok ไม่สำเร็จภายในเวลาที่กำหนด"
        echo "[entrypoint] ใช้วิธีเดิม (หา IP:Port จากหน้า Vast.ai) แทนได้"
    fi
else
    echo "[entrypoint] ไม่พบ NGROK_AUTHTOKEN — ข้ามการเปิด public URL อัตโนมัติ"
    echo "[entrypoint] เข้าผ่าน IP:Port ที่ Vast.ai กำหนดให้แทน (ดูได้ที่หน้า IP & Port Info)"
fi

echo "[entrypoint] Starting Forge Neo..."
exec python3 launch.py --listen --port 7860 --api "$@"
