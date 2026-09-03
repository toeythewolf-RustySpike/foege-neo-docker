#!/bin/bash
set -e

cd /workspace/forge

# --- Fix บั๊ก: host/template บางที่ set PYTORCH_VERSION ไว้ล่วงหน้าแบบไม่มี +cuXXX ---
# ทำให้ launch_utils.py regex parse ไม่ผ่าน (AttributeError: 'NoneType' object has no attribute 'group')
# ดึงค่าจริงจาก torch.__version__ เสมอ แทนที่ env var เดิม
export PYTORCH_VERSION="$(python3 -c "import torch; print(torch.__version__)")"
echo "[entrypoint] PYTORCH_VERSION fixed -> ${PYTORCH_VERSION}"

# --- Fix บั๊ก: requirements.txt ไม่ pin torch version ทำให้ pip resolver อาจดึงเวอร์ชันที่ไม่มี CUDA มาทับ ---
# บังคับ torch version ที่ verified แล้วว่าใช้ได้กับ Forge Neo (ป้องกันปัญหาภาพเทา/ช้าผิดปกติที่เคยเจอ)
export TORCH_COMMAND="pip install torch==2.10.0+cu126 torchvision --extra-index-url https://download.pytorch.org/whl/cu126"  # <-- เพิ่มใหม่
echo "[entrypoint] TORCH_COMMAND pinned -> cu126"  # <-- เพิ่มใหม่

# --- เช็ค CUDA พร้อมใช้งานจริงก่อนเปิด webui (fail เร็ว ดีกว่ารอ error ลึกๆ ทีหลัง) ---
python3 -c "import torch; assert torch.cuda.is_available(), 'CUDA ไม่พร้อมใช้งานบน instance นี้'"

# --- โหลด checkpoint หลักอัตโนมัติ (ถ้ามี CHECKPOINT_URL ส่งมาเป็น environment variable) ---
# ใช้เลือกได้ว่าวันนี้จะเจนรูปด้วย checkpoint ตัวไหน (Z-Image Turbo, Illustrious, ฯลฯ)
# โดยไม่ต้อง SSH เข้าไปพิมพ์เอง — ถ้าไม่ตั้งค่า จะข้ามไป (โหลดทีหลังผ่านคำสั่ง `ckpt <URL>` แทนได้)
source /workspace/scripts/common_download.sh

if [ -n "${CHECKPOINT_URL}" ]; then
    echo "[entrypoint] พบ CHECKPOINT_URL — กำลังโหลด checkpoint หลัก..."
    download_asset "${CHECKPOINT_URL}" "/workspace/forge/models/Stable-diffusion" \
        || echo "[entrypoint] คำเตือน: โหลด checkpoint ไม่สำเร็จ — webui จะเปิดต่อโดยยังไม่มี checkpoint (แก้ทีหลังผ่าน ckpt ได้)"
else
    echo "[entrypoint] ไม่พบ CHECKPOINT_URL — ยังไม่มี checkpoint ให้เลือกตอนเปิด webui"
    echo "[entrypoint] โหลดเพิ่มทีหลังผ่าน SSH ด้วยคำสั่ง: ckpt <URL>"
fi

# --- ถ้าเป็น Z-Image checkpoint (MODEL_ARCH=zimage) ต้องมี text encoder + VAE แยกเสมอ ---
ensure_model_arch_deps "${MODEL_ARCH}" \
    || echo "[entrypoint] คำเตือน: โหลดไฟล์เสริมของ ${MODEL_ARCH} ไม่สำเร็จ — webui จะเปิดต่อ แก้ทีหลังผ่าน SSH ได้"

# --- เปิด ngrok อัตโนมัติ (ถ้ามี NGROK_AUTHTOKEN ส่งมาเป็น environment variable) ---
# เหตุผล: Vast.ai สุ่ม external port ทุก instance ทำให้ต้องเข้า UI ไปหา IP:Port เองทุกครั้ง
# ngrok แก้ปัญหานี้โดยให้ URL คงรูปแบบเดียวกันเสมอ (https://xxxx.ngrok-free.dev)
# หมายเหตุ: authtoken ไม่ได้ฝังอยู่ในไฟล์นี้หรือใน image เลย ต้องส่งผ่าน
#   `-e NGROK_AUTHTOKEN=...` ตอนสร้าง instance เองเท่านั้น — ถ้าไม่ตั้งค่า จะข้าม
#   ส่วนนี้ไปเฉย ๆ แล้วใช้วิธีเดิม (หา IP:Port จากหน้า Vast.ai) แทน
#
# หมายเหตุสำคัญ: เคยลองเปิด 2 tunnel พร้อมกัน (webui + ttyd) มาก่อน แต่พบว่า ngrok
# แผนฟรีให้ "dev domain" เดียวต่อบัญชีเท่านั้น ทุก tunnel เลยได้ URL ซ้ำกันหมด ใช้แยกกันไม่ได้จริง
# (ยืนยันจาก docs ngrok.com/docs/pricing-limits/free-plan-limits) จึงกลับมาใช้ tunnel เดียว
# สำหรับ webui เท่านั้น — ส่วน terminal ให้ใช้ SSH ที่ Vast.ai เปิดให้อยู่แล้วแทน (ไม่มีค่าใช้จ่ายเพิ่ม)

WEBUI_URL=""

if [ -n "${NGROK_AUTHTOKEN}" ]; then
    echo "[entrypoint] พบ NGROK_AUTHTOKEN — กำลังเปิด public URL..."
    ngrok config add-authtoken "${NGROK_AUTHTOKEN}" >/dev/null 2>&1
    nohup ngrok http 7860 --log=/workspace/ngrok.log >/dev/null 2>&1 &

    for i in $(seq 1 15); do
        WEBUI_URL="$(curl -s http://127.0.0.1:4040/api/tunnels 2>/dev/null | jq -r '.tunnels[0].public_url' 2>/dev/null)"
        if [ -n "$WEBUI_URL" ] && [ "$WEBUI_URL" != "null" ]; then
            break
        fi
        sleep 1
    done

    if [ -n "${WEBUI_URL}" ] && [ "${WEBUI_URL}" != "null" ]; then
        echo "=============================================="
        echo "[entrypoint] เข้า Forge Neo ได้ที่: ${WEBUI_URL}"
        echo "[entrypoint] เข้า Terminal (เลือก checkpoint/LoRA) ผ่าน SSH — ดูคำสั่งเชื่อมต่อได้ที่หน้า Instance บน Vast.ai"
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
exec python3 launch.py --listen --port 7860 --api --fp32-vae --enable-insecure-extension-access "$@"
