# ============================================================
# Forge Neo Docker Image — Z-Image / SDXL(Illustrious/Pony) ready
# Base: nvidia/cuda devel (ต้องการ nvcc สำหรับ compile xformers/flash-attn/sage attention)
# Python: 3.11 (เลือกเพราะ mediapipe/insightface/onnxruntime มี wheel รองรับชัวร์กว่า 3.13)
# Torch: pin 2.10.0+cu126 ตรงๆ (อ้างอิงจาก Forge Neo wiki "Extra Installations")
#   เหตุผลที่ต้อง pin แบบนี้: requirements.txt ของ repo (branch neo) มีบรรทัด "torch"
#   แบบไม่ pin version อยู่ท้ายไฟล์ → เคยมีรายงาน (GitHub issue #269) ว่า pip resolver
#   ดึง torch เวอร์ชันใหม่กว่ามาติดตั้งทับจนได้ CPU-only build โดยไม่มี error ตอน build
#   วิธีป้องกัน: ติดตั้ง torch ที่ต้องการก่อน + ใช้ constraints file บังคับ pip ไม่ให้แตะ
#   torch อีกระหว่างติดตั้ง requirements.txt แล้ว verify CUDA ท้าย build
# ============================================================

FROM nvidia/cuda:12.6.3-cudnn-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# ---- System deps ----
# aria2: โหลดไฟล์ใหญ่เร็ว (checkpoint/LoRA จาก CivitAI/HF)
# git: clone Forge Neo repo
# tmux: เผื่อ template ไหนไม่มี auto-tmux (ไม่ได้บังคับสร้างซ้อน แค่ให้มีติดไว้)
# ffmpeg/libgl1: จำเป็นสำหรับ opencv-python / mediapipe ที่ Forge Neo ติดตั้ง
RUN apt-get update && apt-get install -y --no-install-recommends \
    software-properties-common \
    git \
    wget curl \
    aria2 \
    tmux \
    ffmpeg \
    libgl1 \
    libglib2.0-0 \
    build-essential \
    && add-apt-repository -y ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y --no-install-recommends \
    python3.11 \
    python3.11-venv \
    python3.11-dev \
    && rm -rf /var/lib/apt/lists/*

# ทำให้ python3 ชี้ไป 3.11 เสมอ (กัน "ไม่มี python alias" ตามที่เจอมาก่อน)
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1 \
    && curl -sS https://bootstrap.pypa.io/get-pip.py | python3.11

WORKDIR /workspace

# ---- Clone Forge Neo (repo/branch ที่ถูกต้อง — ยืนยันแล้วจาก GitHub ตรงๆ) ----
RUN git clone -b neo https://github.com/Haoming02/sd-webui-forge-classic.git forge

WORKDIR /workspace/forge

# ---- ติดตั้ง torch ที่ pin ไว้ก่อน (ต้องมาก่อน requirements.txt เสมอ) ----
RUN python3 -m pip install --no-cache-dir --upgrade pip \
    && python3 -m pip install --no-cache-dir \
    torch==2.10.0+cu126 torchvision==0.25.0+cu126 \
    --extra-index-url https://download.pytorch.org/whl/cu126

# ---- สร้าง constraints file บังคับ pip ห้ามเปลี่ยน torch/torchvision ระหว่างติดตั้ง requirements.txt ----
RUN python3 -c "import torch, torchvision; \
    print(f'torch=={torch.__version__}'); \
    print(f'torchvision=={torchvision.__version__}')" \
    | sed 's/+cu126//' > /tmp/constraints.txt \
    && cat /tmp/constraints.txt

# ---- ติดตั้ง requirements.txt โดยมี constraints กันไม่ให้ torch หลุด ----
RUN python3 -m pip install --no-cache-dir -r requirements.txt -c /tmp/constraints.txt

# ---- Verify: เช็คว่า torch เป็น "CUDA build" (ไม่ใช่ CPU-only wheel) ----
# หมายเหตุ: docker build ไม่มี GPU device ให้ container (GPU passthrough มีแค่ตอน `docker run --gpus`)
# ดังนั้นเช็คได้แค่ "torch.version.cuda ไม่ใช่ None" (แปลว่าเป็น CUDA wheel) เท่านั้น
# ส่วนเช็คว่า GPU ใช้งานได้จริง (torch.cuda.is_available()) ต้องรอไปเช็คตอน runtime ใน entrypoint.sh
RUN python3 -c "import torch; \
    print('torch version:', torch.__version__); \
    print('torch CUDA build:', torch.version.cuda); \
    assert torch.version.cuda is not None, 'FATAL: torch ที่ติดตั้งเป็น CPU-only wheel ไม่ใช่ CUDA build — build ต้องหยุดตรงนี้'"

# ---- โฟลเดอร์โมเดล (ตามโครงสร้างที่ Forge Neo ใช้จริง) ----
RUN mkdir -p \
    models/Stable-diffusion \
    models/Lora \
    models/text_encoder \
    models/VAE

# ---- Scripts (จะเพิ่มเข้ามาทีหลังตอน launcher scripts นิ่งแล้ว) ----
# COPY scripts/ /workspace/scripts/
# RUN chmod +x /workspace/scripts/*.sh

EXPOSE 7860

# entrypoint จะ export PYTORCH_VERSION ทับ (fix env var bug) ก่อนเรียก launch.py จริง
COPY entrypoint.sh /workspace/entrypoint.sh
RUN chmod +x /workspace/entrypoint.sh

ENTRYPOINT ["/workspace/entrypoint.sh"]
