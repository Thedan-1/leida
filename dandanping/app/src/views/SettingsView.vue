<script setup lang="ts">
import { ref } from 'vue'
import { ElMessage } from 'element-plus'
import { UploadFilled } from '@element-plus/icons-vue'
import { useDashboardStore } from '../stores/dashboard'

const store = useDashboardStore()
const notifyChannels = ref(['大屏弹窗'])

const onUpload = async (uploadFile: { raw?: File }) => {
  if (!uploadFile.raw) return
  try {
    const text = await uploadFile.raw.text()
    const data = JSON.parse(text)
    store.loadFromLegacyJson(data)
    ElMessage.success('历史 JSON 已导入并完成数据映射')
  } catch {
    ElMessage.error('JSON 解析失败，请检查文件格式')
  }
}
</script>

<template>
  <div class="section-grid">
    <div class="panel" style="grid-column: span 6;">
      <div class="panel-head"><div class="panel-title">数据接入与迁移</div></div>
      <div class="panel-body" style="display: flex; flex-direction: column; gap: 12px;">
        <p style="margin: 0; color: #6b7a92;">支持上传你现有大屏的 Report_*.json，系统会自动映射为新平台数据结构。</p>
        <el-upload drag :auto-upload="false" :on-change="onUpload" accept=".json">
          <el-icon style="font-size: 34px;"><UploadFilled /></el-icon>
          <div>拖拽或点击上传 JSON 文件</div>
        </el-upload>
      </div>
    </div>

    <div class="panel" style="grid-column: span 6;">
      <div class="panel-head"><div class="panel-title">平台配置</div></div>
      <div class="panel-body">
        <el-form label-position="top">
          <el-form-item label="数据刷新间隔">
            <el-select model-value="15秒" style="width: 100%;">
              <el-option label="5秒" value="5秒" />
              <el-option label="15秒" value="15秒" />
              <el-option label="30秒" value="30秒" />
            </el-select>
          </el-form-item>
          <el-form-item label="告警推送策略">
            <el-checkbox-group v-model="notifyChannels">
              <el-checkbox label="短信通知" />
              <el-checkbox label="邮件通知" />
              <el-checkbox label="大屏弹窗" />
            </el-checkbox-group>
          </el-form-item>
          <el-button type="primary">保存配置</el-button>
        </el-form>
      </div>
    </div>
  </div>
</template>
