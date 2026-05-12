import urllib.request
import os

# 配置
qr_codes = [
    "POS_01", "POS_02", "POS_03", "POS_04", 
    "POS_05", "POS_06", "POS_07", "POS_08",
    "POS_09", "POS_10", "POS_11", "POS_12",
    "POS_13", "POS_14", "POS_15", "POS_16"
]
size = "300x300" # 像素尺寸
save_dir = "qr_codes"

# 创建目录
if not os.path.exists(save_dir):
    os.makedirs(save_dir)

print(f"正在生成 {len(qr_codes)} 个二维码...")

for code in qr_codes:
    # 使用 goqr.me 的 API (免费，稳定)
    url = f"https://api.qrserver.com/v1/create-qr-code/?size={size}&data={code}"
    save_path = os.path.join(save_dir, f"{code}.png")
    
    try:
        urllib.request.urlretrieve(url, save_path)
        print(f"✅ 已保存: {save_path}")
    except Exception as e:
        print(f"❌ 失败 {code}: {e}")

print("\n完成！请在 'qr_codes' 文件夹中查看。")
