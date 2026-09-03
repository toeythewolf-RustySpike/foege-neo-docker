# ============================================================
# Forge Neo Docker Image — Z-Image / Anima / SDXL(Illustrious/Pony) ready
# Base: nvidia/cuda devel (ต้องการ nvcc สำหรับ compile xformers/flash-attn/sage attention)
# Python: 3.11 (เลือกเพราะ mediapipe/insightface/onnxruntime มี wheel รองรับชัวร์กว่า 3.13)
# Torch: pin 2.10.0+cu126 ตรงๆ (อ้างอิงจาก Forge Neo wiki "Extra Installations")
# ============================================================

FROM nvidia/cuda:12.6.3-cudnn-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# ---- System deps ----
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
    jq \
    && add-apt-repository -y ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y --no-install-recommends \
    python3.11 \
    python3.11-venv \
    python3.11-dev \
    && rm -rf /var/lib/apt/lists/*

# ---- ติดตั้ง ngrok (สำหรับเปิด public URL อัตโนมัติ กัน Vast.ai สุ่ม external port ทุกรอบ) ----
RUN wget -q https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz -O /tmp/ngrok.tgz \
    && tar -xzf /tmp/ngrok.tgz -C /usr/local/bin \
    && rm /tmp/ngrok.tgz

# ทำให้ python3 ชี้ไป 3.11 เสมอ
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1 \
    && curl -sS https://bootstrap.pypa.io/get-pip.py | python3.11

WORKDIR /workspace

# ---- Clone Forge Neo ----
RUN git clone -b neo https://github.com/Haoming02/sd-webui-forge-classic.git forge

WORKDIR /workspace/forge

# ---- ติดตั้ง torch ที่ pin ไว้ก่อน ----
RUN python3 -m pip install --no-cache-dir --upgrade pip \
    && python3 -m pip install --no-cache-dir \
    torch==2.10.0+cu126 torchvision==0.25.0+cu126 \
    --extra-index-url https://download.pytorch.org/whl/cu126

# ---- สร้าง constraints file บังคับ pip ห้ามเปลี่ยน torch/torchvision ----
RUN python3 -c "import torch, torchvision; \
    print(f'torch=={torch.__version__}'); \
    print(f'torchvision=={torchvision.__version__}')" \
    | sed 's/+cu126//' > /tmp/constraints.txt \
    && cat /tmp/constraints.txt

# ---- ติดตั้ง requirements.txt ----
RUN python3 -m pip install --no-cache-dir -r requirements.txt -c /tmp/constraints.txt

# ---- ติดตั้ง requirements.txt ของ extension built-in ทุกตัว ----
RUN for req in extensions-builtin/*/requirements.txt; do \
    if [ -f "$req" ]; then \
    echo "[build] Installing extension requirements: $req"; \
    python3 -m pip install --no-cache-dir -r "$req" -c /tmp/constraints.txt || true; \
    fi; \
