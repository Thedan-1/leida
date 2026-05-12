import { use } from 'echarts/core'
import { CanvasRenderer } from 'echarts/renderers'
import { BarChart, GaugeChart, LineChart, PieChart, RadarChart } from 'echarts/charts'
import { GridComponent, LegendComponent, TooltipComponent, TitleComponent } from 'echarts/components'

use([
  CanvasRenderer,
  BarChart,
  GaugeChart,
  LineChart,
  PieChart,
  RadarChart,
  GridComponent,
  LegendComponent,
  TooltipComponent,
  TitleComponent,
])
