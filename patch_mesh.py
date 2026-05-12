import re

with open('/Users/thedan/Desktop/leida/leida/ContentView.swift', 'r') as f:
    content = f.read()

# Find and replace the mesh visualization logic block
old_pattern = r'''        // 动态响应网格分类显示 \(AI 识别效果\)
        // 只有在 AI 模式下才开启 SceneUnderstanding
        // 强制刷新 debugOptions，防止切换后丢失
        if appModel\.isMeshColoringEnabled && appModel\.coloringMode == \.ai \{
            if !uiView\.debugOptions\.contains\(\.showSceneUnderstanding\) \{
                uiView\.debugOptions\.insert\(\.showSceneUnderstanding\)
            \}
        \} else \{
            if uiView\.debugOptions\.contains\(\.showSceneUnderstanding\) \{
                uiView\.debugOptions\.remove\(\.showSceneUnderstanding\)
            \}
        \}
        
        // 确保物理网格显示 \(如果需要\)
        // 如果用户觉得"格子没了"，可能是 \.showSceneUnderstanding 没生效，或者需要 \.showPhysics
        // 通常 \.showSceneUnderstanding 会显示彩色网格。
        // 如果是在非 AI 模式，我们可能想显示白色网格？
        // 之前的代码只在 AI 模式下显示 SceneUnderstanding。
        // 如果是白模模式，我们应该显示 \.showSceneUnderstanding 吗？
        // ARKit 的 \.showSceneUnderstanding 会覆盖颜色。
        // 如果是白模，我们可能只需要 \.showPhysics 或者 \.showWorldOrigin \(作为参考\)
        // 但用户说"格子"，通常指 Mesh。
        // 如果 sceneReconstruction = \.mesh，ARView 默认会自动渲染 Mesh 吗？
        // RealityKit 的 ARView 会自动渲染 MeshAnchor 对应的 Entity 吗？
        // 不，ARView 需要 debugOptions 才能看到 Mesh，除非我们自己添加了 Entity。
        // 我们的代码没有手动添加 MeshEntity，所以完全依赖 debugOptions。
        // 所以，如果不在 AI 模式，也应该显示 Mesh 线框。
        
        if appModel\.coloringMode == \.none \{
             // 白模模式下，显示物理网格线框
             if !uiView\.debugOptions\.contains\(\.showPhysics\) \{
                 uiView\.debugOptions\.insert\(\.showPhysics\)
             \}
        \} else \{
             if uiView\.debugOptions\.contains\(\.showPhysics\) \{
                 uiView\.debugOptions\.remove\(\.showPhysics\)
             \}
        \}'''

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
        }'''

if re.search(old_pattern, content):
    content = re.sub(old_pattern, new_block, content)
    with open('/Users/thedan/Desktop/leida/leida/ContentView.swift', 'w') as f:
        f.write(content)
    print("SUCCESS: Replaced mesh logic")
else:
    print("FAILED: Could not find old block with regex")
    # Try simpler approach - find by unique marker
    marker = '// 白模模式下，显示物理网格线框'
    if marker in content:
        print(f"Marker found at position: {content.find(marker)}")
    else:
        print("Marker not found either")
