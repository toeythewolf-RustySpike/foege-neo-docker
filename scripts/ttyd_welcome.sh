#!/bin/bash
# สคริปต์นี้ ttyd จะรันทุกครั้งที่มีคนเปิดลิงก์ terminal เข้ามา
# แสดงลิงก์ webui + คำสั่งที่ใช้บ่อย (ckpt/lora) ให้เห็นทันที ไม่ต้องไปงมใน log
# แล้วค่อย exec เข้า shell จริงต่อ (พิมพ์คำสั่งได้ตามปกติ)

clear
echo "=============================================="
if [ -f /workspace/webui_url.txt ]; then
    echo " Forge Neo (webui): $(cat /workspace/webui_url.txt)"
else
    echo " Forge Neo (webui): ยังไม่พร้อม หรือไม่ได้เปิด ngrok ไว้"
fi
echo "=============================================="
echo " คำสั่งที่ใช้บ่อย:"
echo "   ckpt <URL> [zimage]   โหลด checkpoint ใหม่"
echo "   lora <URL1>,<URL2>    โหลด LoRA หลายตัวพร้อมกัน"
echo "=============================================="
echo ""

cd /workspace/forge
exec bash -l
