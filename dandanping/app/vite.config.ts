import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// https://vite.dev/config/
export default defineConfig({
  plugins: [vue()],
  build: {
    chunkSizeWarningLimit: 1200,
    rollupOptions: {
      output: {
        manualChunks: {
          vue: ['vue', 'vue-router', 'pinia'],
          echarts: ['echarts', 'vue-echarts'],
          element: ['element-plus', '@element-plus/icons-vue'],
        },
      },
    },
  },
})
