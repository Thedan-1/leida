import os

html_content = """
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <title>Leida QR Codes</title>
    <style>
        body { font-family: sans-serif; }
        .grid { display: flex; flex-wrap: wrap; justify-content: center; }
        .card { 
            border: 2px solid #333; 
            margin: 10px; 
            padding: 20px; 
            text-align: center; 
            width: 220px;
            page-break-inside: avoid;
        }
        img { width: 200px; height: 200px; image-rendering: pixelated; }
        .label { 
            font-size: 24px; 
            font-weight: bold; 
            margin-top: 10px; 
            display: block;
        }
        @media print {
            .card { border: 1px solid #000; }
        }
    </style>
</head>
<body>
    <h1 style="text-align: center;">Leida Project - 定位二维码</h1>
    <p style="text-align: center;">请打印并剪裁以下二维码，张贴在不同位置。</p>
    <div class="grid">
"""

# Iterate 01 to 16
for i in range(1, 17):
    name = f"POS_{i:02d}"
    filename = f"{name}.png"
    # Assume files are in qr_codes/ relative to this html
    
    html_content += f"""
        <div class="card">
            <img src="qr_codes/{filename}" alt="{name}">
            <span class="label">{name}</span>
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
