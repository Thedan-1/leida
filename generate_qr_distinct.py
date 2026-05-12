
import urllib.request
import urllib.parse
import time
import os

# 定义所有需要生成的位置标识
# 为了增加视觉差异（避免“重复度太高”），我们增加前缀和纠错级别
# 数据格式: LEIDA_ANCHOR_POS_01
qr_data_list = [f"LEIDA_ANCHOR_POS_{i:02d}" for i in range(1, 17)]

# 设置保存目录
output_dir = "qr_codes"
if not os.path.exists(output_dir):
    os.makedirs(output_dir)

# 使用 qrserver.com 的 API 生成二维码
base_url = "https://api.qrserver.com/v1/create-qr-code/"

print(f"正在生成 {len(qr_data_list)} 个高区分度二维码...")

for data_content in qr_data_list:
    # 文件名保持简单 POS_01.png
    filename = data_content.split("_")[-1] + "_" + data_content.split("_")[-1] # This is wrong logic
    # extract POS_01 from LEIDA_ANCHOR_POS_01
    suffix = data_content.split("_")[-2] + "_" + data_content.split("_")[-1] # POS_01
    file_path = os.path.join(output_dir, f"{suffix}.png")
    
    # 构建请求参数
    # size: 尺寸
    # ecc: H (High) - 最高容错率 (30%)。这会增加二维码密度，使得即使数据只有微小差别，生成的图案也会有较大差异。
    params = {
        "size": "300x300",
        "data": data_content,
        "ecc": "H", 
        "margin": "10"
    }
    url = f"{base_url}?{urllib.parse.urlencode(params)}"
    
    print(f"Downloading {suffix} (Data: {data_content})...", end="", flush=True)
    try:
        with urllib.request.urlopen(url, timeout=15) as response:
            with open(file_path, "wb") as f:
                f.write(response.read())
        print(" Done.")
    except Exception as e:
        print(f" Failed: {e}")
    
    # 礼貌性延迟
    time.sleep(1)

print("\n二维码重新生成完毕！")
