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
# รอบนี้เปิด 2 tunnel พร้อมกัน: webui (port 7860) และ ttyd (port 7681 — terminal บนเว็บ)
# แต่ละ tunnel ต้องมี local API คนละพอร์ต (--api-addr) ไม่งั้นตัวที่สองจะชนกับตัวแรก

WEBUI_URL=""
TTYD_URL=""

# ฟังก์ชัน: เปิด ngrok tunnel 1 เส้น แล้วรอดึง public URL ออกมา (คืนค่าผ่าน echo)
start_ngrok_tunnel() {
    local port="$1"
    local api_addr="$2"
    local logfile="$3"

    nohup ngrok http "$port" --api-addr="$api_addr" --log="$logfile" >/dev/null 2>&1 &

    local url=""
    for i in $(seq 1 15); do
        url="$(curl -s "http://${api_addr}/api/tunnels" 2>/dev/null | jq -r '.tunnels[0].public_url' 2>/dev/null)"
        if [ -n "$url" ] && [ "$url" != "null" ]; then
            break
        fi
        sleep 1
    done
    echo "$url"
}

if [ -n "${NGROK_AUTHTOKEN}" ]; then
    echo "[entrypoint] พบ NGROK_AUTHTOKEN — กำลังเปิด public URL (webui + terminal)..."
    ngrok config add-authtoken "${NGROK_AUTHTOKEN}" >/dev/null 2>&1

    WEBUI_URL="$(start_ngrok_tunnel 7860 127.0.0.1:4040 /workspace/ngrok_webui.log)"

    # เขียนลิงก์ webui ไว้ในไฟล์ ให้ ttyd อ่านมาโชว์ตอนเปิด terminal (ไม่ต้องไปงมใน log)
    echo "${WEBUI_URL}" > /workspace/webui_url.txt

    # เปิด ttyd (terminal บนเว็บ) ที่พอร์ต 7681 — รันสคริปต์ต้อนรับก่อนแล้วค่อยเข้า shell จริง
    ttyd -p 7681 /workspace/scripts/ttyd_welcome.sh >/workspace/ttyd.log 2>&1 &

    TTYD_URL="$(start_ngrok_tunnel 7681 127.0.0.1:4041 /workspace/ngrok_ttyd.log)"

    if [ -n "${WEBUI_URL}" ] && [ "${WEBUI_URL}" != "null" ]; then
        echo "=============================================="
        echo "[entrypoint] เข้า Forge Neo ได้ที่: ${WEBUI_URL}"
        if [ -n "${TTYD_URL}" ] && [ "${TTYD_URL}" != "null" ]; then
            echo "[entrypoint] เข้า Terminal (เลือก checkpoint/LoRA) ได้ที่: ${TTYD_URL}"
        else
            echo "[entrypoint] เตือน: เปิด terminal บนเว็บไม่สำเร็จ — ใช้ SSH ปกติแทนได้"
        fi
        echo "=============================================="
    else
        echo "[entrypoint] เตือน: เปิด ngrok ไม่สำเร็จภายในเวลาที่กำหนด"
        echo "[entrypoint] ใช้วิธีเดิม (หา IP:Port จากหน้า Vast.ai) แทนได้"
    fi
else
    echo "[entrypoint] ไม่พบ NGROK_AUTHTOKEN — ข้ามการเปิด public URL อัตโนมัติ (ทั้ง webui และ terminal)"
    echo "[entrypoint] เข้าผ่าน IP:Port ที่ Vast.ai กำหนดให้แทน (ดูได้ที่หน้า IP & Port Info)"
fi

echo "[entrypoint] Starting Forge Neo..."
exec python3 launch.py --listen --port 7860 --api "$@"
