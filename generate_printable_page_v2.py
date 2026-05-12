import os

html_content = """
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <title>Leida QR Codes (High Distinction)</title>
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
            font-size: 20px; 
            font-weight: bold; 
            margin-top: 5px; 
            display: block;
        }
        .sub-label {
            font-size: 10px;
            color: #666;
            margin-top: 2px;
            display: block;
        }
        @media print {
            .card { border: 1px solid #000; }
        }
    </style>
</head>
<body>
    <h1 style="text-align: center;">Leida Project - 定位锚点</h1>
    <p style="text-align: center;">V2 (High ECC) - 请打印并张贴</p>
    <div class="grid">
"""

# Iterate 01 to 16
for i in range(1, 17):
    short_name = f"POS_{i:02d}"
    full_data = f"LEIDA_ANCHOR_{short_name}"
    filename = f"{short_name}.png"
    
    html_content += f"""
        <div class="card">
            <img src="qr_codes/{filename}" alt="{short_name}">
            <span class="label">{short_name}</span>
            <span class="sub-label">{full_data}</span>
        </div>
    """

html_content += """
    </div>
</body>
</html>
"""

with open("qr_codes.html", "w") as f:
    f.write(html_content)

print("Created qr_codes.html")
