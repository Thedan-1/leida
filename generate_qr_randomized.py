
import urllib.request
import urllib.parse
import time
import os
import random
import string

# 生成随机后缀
def generate_random_suffix(length=6):
    return ''.join(random.choices(string.ascii_uppercase + string.digits, k=length))

# 定义所有需要生成的位置标识
# 格式: LEIDA_POS_01_{RANDOM}
# 引入随机后缀会导致由于数据的剧烈变化，整个QR码的矩阵图案发生彻底改变（雪崩效应）
qr_data_list = []
for i in range(1, 17):
    # e.g. LEIDA_POS_01_X7B2K9
    suffix = generate_random_suffix()
    qr_data_list.append(f"LEIDA_POS_{i:02d}_{suffix}")

# 设置保存目录
output_dir = "qr_codes"
if not os.path.exists(output_dir):
    os.makedirs(output_dir)

# 使用 qrserver.com 的 API 生成二维码
base_url = "https://api.qrserver.com/v1/create-qr-code/"

print(f"正在生成 {len(qr_data_list)} 个带有随机干扰的高区分度二维码...")

for data_content in qr_data_list:
    # 提取 POS_01 用于文件名
    # data_content like LEIDA_POS_01_X7B2K9
    # parts: ['LEIDA', 'POS', '01', 'X7B2K9']
    parts = data_content.split("_")
    short_name = f"{parts[1]}_{parts[2]}" # POS_01
    
    file_path = os.path.join(output_dir, f"{short_name}.png")
    
    params = {
        "size": "300x300",
        "data": data_content,
        "ecc": "M", # Medium已经足够，配合随机盐，差异会非常巨大
        "margin": "10"
    }
    url = f"{base_url}?{urllib.parse.urlencode(params)}"
    
    print(f"Downloading {short_name} (Data: {data_content})...", end="", flush=True)
    try:
        with urllib.request.urlopen(url, timeout=15) as response:
            with open(file_path, "wb") as f:
                f.write(response.read())
        print(" Done.")
    except Exception as e:
        print(f" Failed: {e}")
    
    time.sleep(1)

print("\n二维码再次生成完毕！")

# 更新 HTML 生成脚本的引用数据，我们需要把这次生成的完整数据传给HTML脚本
# 虽然HTML脚本是读文件的，但它不知道完整数据字符串是什么了（因为是随机生成的）
# 所以我们在这里直接生成 HTML 比较方便

html_content = """
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <title>Leida QR Codes (Randomized)</title>
    <style>
        body { font-family: sans-serif; }
        .grid { display: flex; flex-wrap: wrap; justify-content: center; }
        .card { 
            border: 2px solid #333; 
            margin: 15px; 
            padding: 15px; 
            text-align: center; 
            width: 200px;
            page-break-inside: avoid;
        }
        img { width: 180px; height: 180px; image-rendering: pixelated; }
        .label { 
            font-size: 24px; 
            font-weight: bold; 
            margin-top: 5px; 
            display: block;
        }
        .sub-label {
            font-size: 10px;
            color: #666;
            margin-top: 2px;
            display: block;
            word-break: break-all;
        }
        @media print {
            .card { border: 1px solid #000; }
        }
    </style>
</head>
<body>
    <h1 style="text-align: center;">Leida Project - 定位锚点</h1>
    <p style="text-align: center;">V3 (Randomized Salt) - 视觉差异最大化</p>
    <div class="grid">
"""

for data_content in qr_data_list:
    parts = data_content.split("_")
    short_name = f"{parts[1]}_{parts[2]}" # POS_01
    filename = f"{short_name}.png"
    
    html_content += f"""
        <div class="card">
            <img src="qr_codes/{filename}" alt="{short_name}">
            <span class="label">{short_name}</span>
            <span class="sub-label">{data_content}</span>
        </div>
    """

html_content += """
    </div>
</body>
</html>
"""

with open("qr_codes.html", "w") as f:
    f.write(html_content)
print("Updated qr_codes.html")

