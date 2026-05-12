<template>
  <div class="legacy-wrap">
    <div class="legacy-tip">
      这是你原来的大屏（含锅炉图、原有模块），已完整保留并嵌入新系统。
    </div>
    <iframe src="/legacy/dashboard_system.html" class="legacy-frame" title="原版锅炉大屏" />
  </div>
</template>

<style scoped>
.legacy-wrap {
  display: flex;
  flex-direction: column;
  gap: 10px;
  height: calc(100vh - 120px);
}

.legacy-tip {
  font-size: 13px;
  color: #5b6c88;
  padding: 8px 12px;
  border: 1px solid #d8e2f2;
  border-radius: 8px;
  background: #ffffffcc;
}

.legacy-frame {
  width: 100%;
  flex: 1;
  border: 1px solid #d8e2f2;
  border-radius: 10px;
  background: #0a0e1a;
}
</style>
