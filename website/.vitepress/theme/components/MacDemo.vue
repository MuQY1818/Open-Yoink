<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { withBase } from 'vitepress'

type DemoPhase = 'ready' | 'dragging-in' | 'stored' | 'dragging-out' | 'delivered'
type DemoModule = 'shelf' | 'media' | 'transfer' | 'timer' | 'battery'

const phase = ref<DemoPhase>('ready')
const islandExpanded = ref(false)
const activeModule = ref<DemoModule>('shelf')
const introStage = ref(0)
const isIntroPlaying = ref(true)
const timerSeconds = ref(25 * 60)
const timerRunning = ref(false)
const mediaPlaying = ref(true)
const transferProgress = ref(68)
const announcements = ref('演示动画即将开始')

const timeText = computed(() => {
  const minutes = Math.floor(timerSeconds.value / 60).toString().padStart(2, '0')
  const seconds = (timerSeconds.value % 60).toString().padStart(2, '0')
  return `${minutes}:${seconds}`
})

const phaseHint = computed(() => {
  if (isIntroPlaying.value) return '正在演示：文件先进入 Island，再送到目标应用'
  switch (phase.value) {
    case 'ready': return '拖动桌面上的“设计稿.fig”，放进屏幕顶部的 Island'
    case 'dragging-in': return '把文件放进展开的 Island'
    case 'stored': return '已暂存。把 Island 里的文件拖到右侧上传区域'
    case 'dragging-out': return '松手，把文件交给目标应用'
    case 'delivered': return '完成。OpenYoink 没有打断你的窗口切换'
  }
})

const timers: number[] = []
let ticker: number | undefined

function later(callback: () => void, delay: number) {
  timers.push(window.setTimeout(callback, delay))
}

function playIntro() {
  timers.splice(0).forEach(window.clearTimeout)
  isIntroPlaying.value = true
  introStage.value = 0
  islandExpanded.value = false
  activeModule.value = 'shelf'
  phase.value = 'ready'
  announcements.value = '开始演示 OpenYoink 的拖入与拖出'
  later(() => { introStage.value = 1 }, 650)
  later(() => { introStage.value = 2; islandExpanded.value = true }, 1_350)
  later(() => { introStage.value = 3 }, 2_250)
  later(() => { introStage.value = 4; islandExpanded.value = false }, 3_050)
  later(() => {
    introStage.value = 0
    isIntroPlaying.value = false
    announcements.value = '演示结束，现在可以亲手体验'
  }, 4_050)
}

function beginSourceDrag(event: DragEvent) {
  if (isIntroPlaying.value || phase.value !== 'ready') {
    event.preventDefault()
    return
  }
  event.dataTransfer?.setData('text/plain', '设计稿.fig')
  if (event.dataTransfer) event.dataTransfer.effectAllowed = 'copy'
  phase.value = 'dragging-in'
  islandExpanded.value = true
  activeModule.value = 'shelf'
  announcements.value = 'Island 已展开，可以放入文件'
}

function dropIntoIsland() {
  if (phase.value !== 'dragging-in') return
  phase.value = 'stored'
  islandExpanded.value = true
  activeModule.value = 'shelf'
  announcements.value = '设计稿已暂存，可以从 Island 继续拖出'
}

function endSourceDrag() {
  if (phase.value === 'dragging-in') {
    phase.value = 'ready'
    islandExpanded.value = false
  }
}

function beginStoredDrag(event: DragEvent) {
  if (phase.value !== 'stored') {
    event.preventDefault()
    return
  }
  event.dataTransfer?.setData('text/plain', '设计稿.fig')
  if (event.dataTransfer) event.dataTransfer.effectAllowed = 'copy'
  phase.value = 'dragging-out'
  announcements.value = '正在把设计稿拖到目标应用'
}

function dropIntoTarget() {
  if (phase.value !== 'dragging-out') return
  phase.value = 'delivered'
  announcements.value = '设计稿已送达目标应用'
}

function endStoredDrag() {
  if (phase.value === 'dragging-out') phase.value = 'stored'
}

function resetDemo() {
  phase.value = 'ready'
  islandExpanded.value = false
  activeModule.value = 'shelf'
  announcements.value = '演示已重置'
}

function performGuidedAction() {
  if (isIntroPlaying.value) return
  if (phase.value === 'ready') {
    islandExpanded.value = true
    phase.value = 'stored'
    announcements.value = '设计稿已暂存'
  } else if (phase.value === 'stored') {
    phase.value = 'delivered'
    announcements.value = '设计稿已送达目标应用'
  } else {
    resetDemo()
  }
}

function selectModule(module: DemoModule) {
  if (isIntroPlaying.value) return
  activeModule.value = module
  islandExpanded.value = true
  announcements.value = `已打开${module === 'shelf' ? '暂存架' : module === 'media' ? '正在播放' : module === 'transfer' ? '传输' : module === 'timer' ? '计时器' : '电池'}模块`
}

function toggleIsland() {
  if (isIntroPlaying.value) return
  islandExpanded.value = !islandExpanded.value
  announcements.value = islandExpanded.value ? 'Island 已展开' : 'Island 已收起'
}

function chooseTimer(minutes: number) {
  timerSeconds.value = minutes * 60
  timerRunning.value = false
}

function toggleTimer() {
  timerRunning.value = !timerRunning.value
}

onMounted(() => {
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches
  if (reduceMotion) {
    isIntroPlaying.value = false
    announcements.value = '可以开始体验 OpenYoink'
  } else {
    playIntro()
  }
  ticker = window.setInterval(() => {
    if (timerRunning.value && timerSeconds.value > 0) timerSeconds.value -= 1
    if (timerRunning.value && timerSeconds.value === 0) timerRunning.value = false
    if (activeModule.value === 'transfer' && islandExpanded.value) {
      transferProgress.value = transferProgress.value >= 96 ? 34 : transferProgress.value + 1
    }
  }, 1_000)
})

onBeforeUnmount(() => {
  timers.forEach(window.clearTimeout)
  if (ticker !== undefined) window.clearInterval(ticker)
})
</script>

<template>
  <div class="mac-demo-shell" :class="{ 'is-intro': isIntroPlaying }">
    <div class="mac-demo-toolbar">
      <div>
        <span class="mac-live-dot"></span>
        <b>{{ isIntroPlaying ? '自动演示' : '现在轮到你' }}</b>
        <span>{{ phaseHint }}</span>
      </div>
      <button type="button" @click="playIntro">重播动画</button>
    </div>

    <div class="macbook" aria-label="可交互的虚拟 MacBook">
      <div class="mac-screen">
        <div class="mac-wallpaper"></div>
        <div class="mac-menubar" aria-hidden="true">
          <b class="mac-apple"></b><strong>Finder</strong><span>文件</span><span>编辑</span><span>显示</span><span>前往</span>
          <i></i>
          <span class="mac-status">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M4 10.5a12 12 0 0 1 16 0"/><path d="M7.5 14a7.5 7.5 0 0 1 9 0"/><path d="M11 17.4a3.2 3.2 0 0 1 2 0"/><circle cx="12" cy="19.4" r="1" fill="currentColor" stroke="none"/></svg>
          </span>
          <span class="mac-status">
            <svg viewBox="0 0 24 24" fill="currentColor"><rect x="3" y="4.5" width="18" height="6" rx="3" opacity=".45"/><rect x="3" y="13.5" width="18" height="6" rx="3" opacity=".45"/><circle cx="17.5" cy="7.5" r="2.1"/><circle cx="6.5" cy="16.5" r="2.1"/></svg>
          </span>
          <span class="mac-battery-mini"><em></em></span><time>10:09</time>
        </div>

        <div
          class="web-island"
          :class="{ expanded: islandExpanded, 'drop-ready': phase === 'dragging-in' }"
          @dragover.prevent
          @drop.prevent="dropIntoIsland"
        >
          <button
            v-if="!islandExpanded"
            class="island-compact"
            type="button"
            aria-label="展开 OpenYoink Island"
            @click="toggleIsland"
          >
            <span class="mini-tray">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h16v4a4 4 0 0 1-4 4h-1a3 3 0 0 1-6 0H8a4 4 0 0 1-4-4Z"/><path d="M9 4.5 10.5 8M15 4.5 13.5 8"/></svg>
            </span>
            <span class="camera"></span>
            <span class="mini-bars"><i></i><i></i><i></i><i></i></span>
          </button>

          <div v-else class="island-expanded">
            <div class="island-tabs" role="tablist" aria-label="Island 模块">
              <button :class="{ active: activeModule === 'shelf' }" type="button" role="tab" @click="selectModule('shelf')" aria-label="暂存架">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h16v4a4 4 0 0 1-4 4h-1a3 3 0 0 1-6 0H8a4 4 0 0 1-4-4Z"/><path d="M9 4.5 10.5 8M15 4.5 13.5 8"/></svg>
              </button>
              <button :class="{ active: activeModule === 'media' }" type="button" role="tab" @click="selectModule('media')" aria-label="正在播放">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18V6l11-2v12"/><circle cx="6.5" cy="18" r="2.5"/><circle cx="17.5" cy="16" r="2.5"/></svg>
              </button>
              <button :class="{ active: activeModule === 'transfer' }" type="button" role="tab" @click="selectModule('transfer')" aria-label="传输">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M8 4 4 8l4 4"/><path d="M4 8h13"/><path d="m16 20 4-4-4-4"/><path d="M20 16H7"/></svg>
              </button>
              <button :class="{ active: activeModule === 'timer' }" type="button" role="tab" @click="selectModule('timer')" aria-label="计时器">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="13.5" r="7.5"/><path d="M12 9.5v4l2.6 2"/><path d="M9.5 3h5"/></svg>
              </button>
              <button :class="{ active: activeModule === 'battery' }" type="button" role="tab" @click="selectModule('battery')" aria-label="电池">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="8" width="17" height="9" rx="2.5"/><path d="M21.5 11v3"/><rect x="5" y="10.5" width="8" height="4" rx="1" fill="currentColor" stroke="none"/></svg>
              </button>
              <button class="island-collapse" type="button" aria-label="收起 Island" @click="toggleIsland"><i></i></button>
            </div>

            <section v-if="activeModule === 'shelf'" class="island-pane shelf-pane">
              <header>
                <p><b>暂存架</b><small>{{ phase === 'stored' || phase === 'dragging-out' ? '3 个项目' : '2 个项目' }}</small></p>
                <span>拖入这里，稍后继续</span>
              </header>
              <div class="demo-shelf-items">
                <div class="shelf-file"><span class="doc doc-purple"><i>PDF</i></span><p><b>产品方向.pdf</b><small>2.4 MB</small></p></div>
                <div class="shelf-file"><span class="doc doc-blue"><i>IMG</i></span><p><b>参考图.png</b><small>842 KB</small></p></div>
                <div
                  v-if="phase === 'stored' || phase === 'dragging-out'"
                  class="shelf-file stored-file"
                  draggable="true"
                  @dragstart="beginStoredDrag"
                  @dragend="endStoredDrag"
                ><span class="doc doc-amber"><i>FIG</i></span><p><b>设计稿.fig</b><small>18 MB</small></p></div>
              </div>
            </section>

            <section v-else-if="activeModule === 'media'" class="island-pane media-pane">
              <div class="album-art"><i></i></div>
              <div class="media-info">
                <small>正在播放</small><b>Night Drive</b><span>Open Source Ensemble</span>
                <div class="media-progress"><i></i></div>
                <em>01:42</em>
              </div>
              <button type="button" :aria-label="mediaPlaying ? '暂停' : '播放'" @click="mediaPlaying = !mediaPlaying">
                <svg v-if="mediaPlaying" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="5" width="4.2" height="14" rx="1.4"/><rect x="13.8" y="5" width="4.2" height="14" rx="1.4"/></svg>
                <svg v-else viewBox="0 0 24 24" fill="currentColor"><path d="M8 5.4c0-1 1.1-1.6 2-1.1l10 5.9c.8.5.8 1.7 0 2.2l-10 5.9c-.9.5-2-.1-2-1.1Z"/></svg>
              </button>
            </section>

            <section v-else-if="activeModule === 'transfer'" class="island-pane transfer-pane">
              <header><p><b>传输</b><small>正在接收文件</small></p><strong>{{ transferProgress }}<i>%</i></strong></header>
              <div class="transfer-track"><i :style="{ width: `${transferProgress}%` }"></i></div>
              <div class="transfer-file"><span class="doc doc-purple"><i>ZIP</i></span><p><b>OpenYoink-assets.zip</b><small>84.2 MB / 124 MB</small></p></div>
            </section>

            <section v-else-if="activeModule === 'timer'" class="island-pane timer-pane">
              <header><p><b>专注计时器</b><small>{{ timerRunning ? '保持专注' : '选择时长' }}</small></p></header>
              <strong class="timer-value">{{ timeText }}</strong>
              <div class="timer-foot">
                <div class="timer-presets"><button v-for="minutes in [5, 15, 25, 45]" :key="minutes" type="button" @click="chooseTimer(minutes)">{{ minutes }}m</button></div>
                <button class="timer-main" type="button" @click="toggleTimer">{{ timerRunning ? '暂停' : '开始' }}</button>
              </div>
            </section>

            <section v-else class="island-pane battery-pane">
              <header><p><b>电池</b><small>已接通电源</small></p><span>82%</span></header>
              <div class="battery-hero">
                <strong>82</strong><small>%</small>
                <i><svg viewBox="0 0 24 24" fill="currentColor"><path d="M13 2 4.5 13.5H11L9.5 22 19 9.5h-6.5Z"/></svg></i>
              </div>
              <div class="battery-track"><i></i></div>
              <footer><span>预计 38 分钟充满</span><b>电池状态正常</b></footer>
            </section>
          </div>
        </div>

        <div class="finder-window" aria-hidden="true">
          <div class="finder-toolbar">
            <span class="traffic red"></span><span class="traffic yellow"></span><span class="traffic green"></span>
            <button>‹</button><button>›</button><b>项目资料</b><i></i>
            <svg class="finder-search" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><circle cx="11" cy="11" r="6.5"/><path d="m20 20-3.8-3.8"/></svg>
          </div>
          <div class="finder-body">
            <aside><b>个人收藏</b><span class="selected">最近使用</span><span>桌面</span><span>文稿</span><span>下载</span></aside>
            <main>
              <div><i class="folder-icon"></i><span>设计</span></div>
              <div><i class="folder-icon purple"></i><span>素材</span></div>
              <div><i class="document-icon">PDF</i><span>项目说明</span></div>
            </main>
          </div>
        </div>

        <div class="desktop-file-wrap">
          <div
            v-if="phase === 'ready' || phase === 'dragging-in'"
            class="desktop-file"
            :draggable="!isIntroPlaying"
            @dragstart="beginSourceDrag"
            @dragend="endSourceDrag"
          ><span class="file-doc">FIG</span><b>设计稿.fig</b></div>
          <p>桌面</p>
        </div>

        <div class="browser-window">
          <div class="browser-chrome"><i></i><i></i><i></i><b>+</b><span>example.design/upload</span><em>⋯</em></div>
          <div
            class="upload-target"
            :class="{ active: phase === 'dragging-out', complete: phase === 'delivered' }"
            @dragover.prevent
            @drop.prevent="dropIntoTarget"
          >
            <span class="upload-glyph">
              <svg v-if="phase === 'delivered'" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12.5 4.5 4.5L19 7.5"/></svg>
              <svg v-else viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4v11"/><path d="m6.5 10.5 5.5 5.5 5.5-5.5"/><path d="M5 20h14"/></svg>
            </span>
            <b>{{ phase === 'delivered' ? '设计稿已送达' : '把文件拖到这里' }}</b>
            <small>{{ phase === 'delivered' ? '目标应用已收到副本' : '网页上传区域' }}</small>
          </div>
        </div>

        <div v-if="isIntroPlaying" class="intro-token" :class="`stage-${introStage}`"><span class="doc doc-amber"><i>FIG</i></span><b>设计稿.fig</b></div>
        <div class="mac-dock" aria-hidden="true">
          <span class="dock-tile dock-finder">
            <svg viewBox="0 0 24 24"><path fill="#dff0ff" d="M12 2.5A9.5 9.5 0 0 0 2.5 12c0 2.6 1 5 2.8 6.7V21l2.6-1.4c1.2.5 2.6.8 4.1.8a9.5 9.5 0 0 0 0-19Z"/><path fill="#1f7ae0" d="M12 2.5A9.5 9.5 0 0 1 21.5 12c0 2.6-1 5-2.8 6.7V21l-2.6-1.4a9.6 9.6 0 0 1-4.1.8 9.5 9.5 0 0 1 0-19Z" opacity=".92"/><path d="M8 9.2v2.6M16 9.2v2.6" stroke="#fff" stroke-width="1.7" stroke-linecap="round"/><path d="M7.5 14.5c1.2 1 2.7 1.6 4.5 1.6s3.3-.6 4.5-1.6" stroke="#fff" stroke-width="1.7" stroke-linecap="round" fill="none"/></svg>
          </span>
          <span class="dock-tile dock-app"><img :src="withBase('/images/icon.png')" alt=""></span>
          <span class="dock-tile dock-browser">
            <svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9.5" fill="#f4f7fb"/><path d="m15.5 8.5-2 5-5 2 2-5Z" fill="#2a7de1"/><circle cx="12" cy="12" r="1.1" fill="#f4f7fb"/></svg>
          </span>
          <span class="dock-tile dock-mail">
            <svg viewBox="0 0 24 24"><rect x="3" y="5.5" width="18" height="13" rx="2.2" fill="#fff"/><path d="m4 7 8 6 8-6" stroke="#3f8eea" stroke-width="1.8" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>
          </span>
          <span class="dock-tile dock-folder">
            <svg viewBox="0 0 24 24"><path fill="#58b8e8" d="M3.5 6.5c0-1.1.9-2 2-2h4l2 2.5h7c1.1 0 2 .9 2 2v8.5c0 1.1-.9 2-2 2h-13c-1.1 0-2-.9-2-2Z"/><path fill="#8fd0f5" d="M3.5 9.5h17v8c0 1.1-.9 2-2 2h-13c-1.1 0-2-.9-2-2Z"/></svg>
          </span>
        </div>
      </div>
      <div class="mac-lid"><i></i></div>
    </div>

    <div class="mac-demo-controls">
      <p aria-live="polite">{{ announcements }}</p>
      <div>
        <button type="button" :disabled="isIntroPlaying" @click="performGuidedAction">
          {{ phase === 'ready' ? '放入 Island' : phase === 'stored' ? '送到目标应用' : '重新体验' }}
        </button>
        <button v-if="!isIntroPlaying && islandExpanded" type="button" class="quiet" @click="toggleIsland">收起 Island</button>
      </div>
    </div>
  </div>
</template>
