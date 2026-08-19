<script setup lang="ts">
import { withBase } from 'vitepress'
import MacDemo from './MacDemo.vue'

const downloadURL = 'https://github.com/MuQY1818/OpenYoink/releases/latest'
const repository = 'https://github.com/MuQY1818/OpenYoink'

const features = [
  {
    icon: 'cursor',
    title: '拖入，再继续拖',
    body: '跨窗口、Space 和全屏应用搬运内容时，不必把所有窗口预先排好。先放到屏幕边缘，再拖到目标。'
  },
  {
    icon: 'notch',
    title: '刘海不再只是黑边',
    body: '有物理刘海时自然融合；外接屏或无刘海设备则使用顶部悬浮胶囊。'
  },
  {
    icon: 'shield',
    title: '真正属于本机',
    body: '暂存架、计时器和设置都保存在本机，没有账号、云同步与行为分析。'
  }
]

const guides = [
  { tag: '安装', text: 'Homebrew、DMG 与首次启动', link: '/guide/install' },
  { tag: '上手', text: '完成第一次拖入和拖出', link: '/guide/quick-start' },
  { tag: 'Island', text: '展开、收起与模块配置', link: '/guide/island' },
  { tag: '安全', text: '引用、物化与托管移动', link: '/guide/file-safety' },
  { tag: '排障', text: '打不开、更新失败与拖放问题', link: '/guide/troubleshooting' }
]
</script>

<template>
  <div class="oy-home">
    <header class="oy-nav" aria-label="主导航">
      <a class="oy-brand" :href="withBase('/')" aria-label="OpenYoink 首页">
        <img :src="withBase('/images/icon.png')" alt="" width="30" height="30">
        <span>OpenYoink</span>
      </a>
      <nav>
        <a href="#try">在线体验</a>
        <a :href="withBase('/guide/')">使用文档</a>
        <a :href="repository">GitHub</a>
        <a class="oy-nav-download" :href="downloadURL">下载</a>
      </nav>
    </header>

    <main>
      <section class="oy-hero">
        <div class="oy-container">
          <p class="oy-kicker">
            <img :src="withBase('/images/icon.png')" alt="" width="20" height="20">
            <span>OpenYoink for macOS 15+</span>
            <span class="oy-pill">v1.4.1 · MIT</span>
          </p>
          <h1>
            <span class="oy-h1-line">随手一拖，</span>
            <span class="oy-h1-line oy-grad">随取随用。</span>
          </h1>
          <p class="oy-lead">
            文件先放进屏幕边缘或 Mac 刘海，切换窗口后再继续拖。一个安静、免费的开源暂存空间。
          </p>
          <div class="oy-actions">
            <a class="oy-button oy-button-primary" :href="downloadURL">下载稳定版</a>
            <a class="oy-link" :href="withBase('/guide/quick-start')">三分钟上手<span class="oy-chevron" aria-hidden="true">›</span></a>
          </div>
          <ul class="oy-bullets">
            <li>无账号</li>
            <li>无遥测</li>
            <li>Apple Silicon 与 Intel</li>
          </ul>

          <figure class="oy-hero-media">
            <div class="oy-media-bar" aria-hidden="true">
              <span class="oy-traffic"><i></i><i class="y"></i><i class="g"></i></span>
              <b>真实录屏 · 选中，拖入屏幕边缘，再拖出</b>
              <span class="oy-media-bar-side"></span>
            </div>
            <video
              :src="withBase('/images/usage-demo.mp4')"
              :poster="withBase('/images/usage-demo-poster.jpg')"
              autoplay
              muted
              loop
              playsinline
              aria-label="OpenYoink 真实使用录屏：选中文件拖入屏幕右侧的暂存架，切换到目标窗口后再拖出"
            ></video>
          </figure>
          <p class="oy-hero-caption">真实录屏，未做加速处理。暂存内容在侧边架与 Island 之间同步。</p>
        </div>
      </section>

      <section id="try" class="oy-band">
        <div class="oy-container oy-demo-container">
          <div class="oy-section-heading">
            <p class="oy-eyebrow">TRY IT IN YOUR BROWSER</p>
            <h2>先看一次，再亲手拖一次</h2>
            <p>这是一台运行“网页版 OpenYoink”的虚拟 Mac。动画结束后，可以点击刘海、切换模块，或把示例文件拖进再拖出。</p>
          </div>
          <MacDemo />
          <p class="oy-demo-privacy">这是本地交互演示，不会读取、上传或保存你的文件。</p>
        </div>
      </section>

      <section class="oy-story">
        <div class="oy-container">
          <div class="oy-section-heading oy-heading-left">
            <p class="oy-eyebrow">ONE SHELF, TWO ENTRANCES</p>
            <h2>侧边暂存架与 Island，共享同一个空间</h2>
            <p>你可以只用经典侧边暂存架、只把 Island 当作桌面信息中心，也可以同时开启两者。入口各自独立，内容保持同步。</p>
          </div>
          <div class="oy-feature-grid">
            <article v-for="f in features" :key="f.title">
              <span class="oy-feature-icon" aria-hidden="true">
                <svg v-if="f.icon === 'cursor'" viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
                  <path d="m5 3 6 16 2.5-6.5L20 10Z"/>
                </svg>
                <svg v-else-if="f.icon === 'notch'" viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
                  <rect x="2.5" y="4" width="19" height="16" rx="3"/>
                  <path d="M8 4v3a4 4 0 0 0 8 0V4"/>
                </svg>
                <svg v-else viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
                  <path d="M12 3 4 6v6c0 4.5 3.2 8.4 8 9 4.8-.6 8-4.5 8-9V6Z"/>
                  <path d="m9 12 2 2 4-4"/>
                </svg>
              </span>
              <h3>{{ f.title }}</h3>
              <p>{{ f.body }}</p>
            </article>
          </div>
        </div>
      </section>

      <div class="oy-container">
        <section class="oy-island">
          <div class="oy-island-copy">
            <p class="oy-eyebrow">OPENYOINK ISLAND</p>
            <h2>不只是一块暂存架</h2>
            <p>暂存、传输、计时器、电池和正在播放，都收进同一块与刘海融为一体的面板。模块各自独立开关，不需要的功能不会打扰你。</p>
            <a class="oy-island-link" :href="withBase('/guide/island')">了解 Island 的使用方式<span class="oy-chevron" aria-hidden="true">›</span></a>
          </div>
          <div class="oy-island-stage" aria-hidden="true">
            <div class="oy-island-panel">
              <div class="oy-panel-head">
                <span class="oy-panel-tabs">
                  <span class="on"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h16v4a4 4 0 0 1-4 4h-1a3 3 0 0 1-6 0H8a4 4 0 0 1-4-4Z"/><path d="M9 4.5 10.5 8M15 4.5 13.5 8"/></svg></span>
                  <span><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18V6l11-2v12"/><circle cx="6.5" cy="18" r="2.5"/><circle cx="17.5" cy="16" r="2.5"/></svg></span>
                  <span><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M8 4 4 8l4 4"/><path d="M4 8h13"/><path d="m16 20 4-4-4-4"/><path d="M20 16H7"/></svg></span>
                  <span><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="13.5" r="7.5"/><path d="M12 9.5v4l2.6 2"/><path d="M9.5 3h5"/></svg></span>
                  <span><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="8" width="17" height="9" rx="2.5"/><path d="M21.5 11v3"/><rect x="5" y="10.5" width="8" height="4" rx="1" fill="currentColor" stroke="none"/></svg></span>
                </span>
                <span class="oy-panel-grip"></span>
              </div>
              <div class="oy-panel-body">
                <div class="oy-panel-title"><b>暂存架</b><small>3 个项目</small></div>
                <div class="oy-panel-files">
                  <div class="oy-panel-file"><span class="doc doc-purple"><i>PDF</i></span><b>产品方向.pdf</b><small>2.4 MB</small></div>
                  <div class="oy-panel-file"><span class="doc doc-blue"><i>IMG</i></span><b>参考图.png</b><small>842 KB</small></div>
                  <div class="oy-panel-file"><span class="doc doc-amber"><i>FIG</i></span><b>设计稿.fig</b><small>18 MB</small></div>
                </div>
                <div class="oy-panel-media">
                  <span class="oy-panel-cover"></span>
                  <p><b>Night Drive</b><small>Open Source Ensemble</small></p>
                  <span class="oy-panel-eq"><i></i><i></i><i></i><i></i></span>
                </div>
              </div>
            </div>
            <div class="oy-island-pill">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h16v4a4 4 0 0 1-4 4h-1a3 3 0 0 1-6 0H8a4 4 0 0 1-4-4Z"/><path d="M9 4.5 10.5 8M15 4.5 13.5 8"/></svg>
              <span class="oy-pill-cam"></span>
              <span class="oy-pill-eq"><i></i><i></i><i></i></span>
              <span class="oy-pill-count">3</span>
            </div>
          </div>
        </section>
      </div>

      <section class="oy-band">
        <div class="oy-container">
          <div class="oy-section-heading oy-heading-left">
            <p class="oy-eyebrow">REAL APP, REAL PIXELS</p>
            <h2>它真的长在 Mac 顶部</h2>
            <p>下面是 v1.4.1 在真实刘海屏上的画面。黑色轮廓与屏幕顶边连续，内容按模块切换，不会用一块通用浮窗冒充 Island。</p>
          </div>
          <div class="oy-shot-grid">
            <figure>
              <img :src="withBase('/screenshots/island-media.png')" alt="OpenYoink Island 正在播放模块" loading="lazy">
              <figcaption><b>正在播放</b><span>封面取色、可拖动进度与本机媒体控制</span></figcaption>
            </figure>
            <figure>
              <img :src="withBase('/screenshots/island-timer.png')" alt="OpenYoink Island 计时器模块" loading="lazy">
              <figcaption><b>专注计时</b><span>运行、暂停与跨启动恢复</span></figcaption>
            </figure>
            <figure>
              <img :src="withBase('/screenshots/island-shelf.png')" alt="OpenYoink Island 暂存架模块" loading="lazy">
              <figcaption><b>共享暂存架</b><span>与侧边架共用同一组内容</span></figcaption>
            </figure>
            <figure>
              <img :src="withBase('/screenshots/island-battery.png')" alt="OpenYoink Island 电池模块" loading="lazy">
              <figcaption><b>电池</b><span>事件驱动，不在后台持续轮询</span></figcaption>
            </figure>
          </div>
          <p class="oy-preview-note">实机界面会随屏幕尺寸、系统语言与正在播放的内容自然适配。</p>
        </div>
      </section>

      <section class="oy-guide">
        <div class="oy-container">
          <div class="oy-section-heading oy-heading-left">
            <p class="oy-eyebrow">DOCUMENTATION</p>
            <h2>从安装到文件安全，都讲清楚</h2>
            <p>官网文档不只告诉你“按哪个按钮”，也会说明文件究竟存在哪里、什么时候会被复制，以及遇到系统拦截时如何处理。</p>
          </div>
          <div class="oy-guide-links">
            <a v-for="g in guides" :key="g.link" :href="withBase(g.link)">
              <span>{{ g.tag }}</span>
              <b>{{ g.text }}</b>
              <i class="oy-chevron" aria-hidden="true">›</i>
            </a>
          </div>
        </div>
      </section>

      <div class="oy-container">
        <section class="oy-final">
          <img :src="withBase('/images/icon.png')" alt="OpenYoink 图标" width="64" height="64">
          <h2>让拖拽少绕一点路。</h2>
          <p>免费下载，开源透明。需要时出现，用完后安静收起。</p>
          <div class="oy-actions">
            <a class="oy-button oy-button-primary" :href="downloadURL">从 GitHub 下载</a>
            <a class="oy-link" :href="withBase('/guide/')">阅读使用文档<span class="oy-chevron" aria-hidden="true">›</span></a>
          </div>
        </section>
      </div>
    </main>

    <footer class="oy-footer">
      <div class="oy-container">
        <div class="oy-footer-brand"><b>OpenYoink</b><span>随手一拖，随取随用。</span></div>
        <nav>
          <a :href="withBase('/en/')">English</a>
          <a :href="`${repository}/issues`">反馈问题</a>
          <a :href="`${repository}/blob/main/LICENSE`">MIT License</a>
        </nav>
      </div>
    </footer>
  </div>
</template>
