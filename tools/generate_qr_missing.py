
import urllib.request
import urllib.parse
import time
import os

# 定义所有需要生成的位置标识
qr_data_list = [
    "POS_09", "POS_10", "POS_11", "POS_12", 
    "POS_13", "POS_14", "POS_15", "POS_16"
]

# 设置保存目录
output_dir = "qr_codes"
if not os.path.exists(output_dir):
    os.makedirs(output_dir)

# 使用 qrserver.com 的 API 生成二维码
base_url = "https://api.qrserver.com/v1/create-qr-code/"

print(f"正在尝试下载剩余的 {len(qr_data_list)} 个二维码...")

for data_content in qr_data_list:
    file_path = os.path.join(output_dir, f"{data_content}.png")
    
    # 如果文件已经存在且大小正常（>0），跳过
    if os.path.exists(file_path) and os.path.getsize(file_path) > 0:
        print(f"Skipping {data_content} (already exists)")
        continue

    # 构建请求参数：尺寸 300x300
    params = {
        "size": "300x300",
        "data": data_content
    }
    url = f"{base_url}?{urllib.parse.urlencode(params)}"
    
    print(f"Downloading {data_content}...", end="", flush=True)
    try:
        # 增加超时以防卡住
        with urllib.request.urlopen(url, timeout=10) as response:
            with open(file_path, "wb") as f:
                f.write(response.read())
        print(" Done.")
    except Exception as e:
        print(f" Failed: {e}")
    
    # 礼貌性延迟，避免请求过快
    time.sleep(1)

print("\n所有剩余二维码处理完毕！")
