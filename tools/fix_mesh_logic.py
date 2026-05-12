#!/usr/bin/env python3
import sys

# Read the file
with open('/Users/thedan/Desktop/leida/leida/ContentView.swift', 'r', encoding='utf-8') as f:
    lines = f.readlines()

# Find the start line (line 2721 in 1-indexed = index 2720)
start_idx = 2720  # 0-indexed
end_idx = 2760    # line 2761 (exclusive in range), so lines 2721-2760

new_block = '''        // ========== 网格可视化逻辑 ==========
        // isLiDAREnabled: 控制是否有网格数据 (sceneReconstruction)
        // isMeshColoringEnabled + coloringMode: 控制网格如何显示颜色
        //
        // 显示方式:
        // - .showSceneUnderstanding: 显示带 AI 语义分类颜色的网格
        // - .showAnchorGeometry: 显示白色/灰色的网格几何体
        
        if appModel.isLiDAREnabled {
            // LiDAR 开启时，根据着色模式选择显示方式
            if appModel.isMeshColoringEnabled && appModel.coloringMode == .ai {
                // AI 语义模式：显示彩色分类网格
                if !uiView.debugOptions.contains(.showSceneUnderstanding) {
                    uiView.debugOptions.insert(.showSceneUnderstanding)
                }
                uiView.debugOptions.remove(.showAnchorGeometry)
            } else {
                // 白模模式：显示灰色/白色网格几何
                if !uiView.debugOptions.contains(.showAnchorGeometry) {
                    uiView.debugOptions.insert(.showAnchorGeometry)
                }
                uiView.debugOptions.remove(.showSceneUnderstanding)
            }
        } else {
            // LiDAR 关闭时，不显示任何网格
            uiView.debugOptions.remove(.showSceneUnderstanding)
            uiView.debugOptions.remove(.showAnchorGeometry)
        }
'''

# Replace lines 2721-2760 with the new block
new_lines = lines[:start_idx] + [new_block] + lines[end_idx:]

# Write back
with open('/Users/thedan/Desktop/leida/leida/ContentView.swift', 'w', encoding='utf-8') as f:
    f.writelines(new_lines)

print(f"SUCCESS: Replaced lines {start_idx+1}-{end_idx} with new mesh logic")
