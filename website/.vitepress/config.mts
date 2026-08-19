import { defineConfig } from 'vitepress'

const repository = 'https://github.com/MuQY1818/OpenYoink'

export default defineConfig({
  title: 'OpenYoink',
  description: '随手一拖，先放一下。免费的开源 macOS 拖拽暂存架与灵动岛。',
  lang: 'zh-CN',
  base: '/OpenYoink/',
  appearance: 'force-dark',
  cleanUrls: true,
  lastUpdated: true,
  sitemap: {
    hostname: 'https://muqy1818.github.io/OpenYoink/'
  },
  head: [
    ['link', { rel: 'icon', href: '/OpenYoink/images/icon.png' }],
    ['meta', { name: 'theme-color', content: '#ffffff' }],
    ['meta', { property: 'og:type', content: 'website' }],
    ['meta', { property: 'og:title', content: 'OpenYoink — 随手一拖，先放一下' }],
    ['meta', { property: 'og:description', content: '免费的开源 macOS 拖拽暂存架与灵动岛。' }]
  ],
  locales: {
    root: {
      label: '简体中文',
      lang: 'zh-CN',
      title: 'OpenYoink',
      description: '随手一拖，先放一下。'
    },
    en: {
      label: 'English',
      lang: 'en-US',
      title: 'OpenYoink',
      description: 'Drag now. Drop later.',
      themeConfig: {
        nav: [
          { text: 'Guide', link: '/en/guide/' },
          { text: 'Island', link: '/en/guide/island' },
          { text: 'Download', link: `${repository}/releases/latest` }
        ],
        sidebar: {
          '/en/guide/': [
            {
              text: 'Get started',
              items: [
                { text: 'Overview', link: '/en/guide/' },
                { text: 'Quick start', link: '/en/guide/quick-start' },
                { text: 'OpenYoink Island', link: '/en/guide/island' },
                { text: 'File safety', link: '/en/guide/file-safety' }
              ]
            }
          ]
        },
        footer: {
          message: 'OpenYoink is an independent open-source project and is not affiliated with the commercial Yoink app.',
          copyright: 'MIT License · © 2026 OpenYoink contributors'
        },
        outline: { label: 'On this page' },
        docFooter: { prev: 'Previous', next: 'Next' },
        lastUpdated: { text: 'Last updated' },
        returnToTopLabel: 'Back to top',
        sidebarMenuLabel: 'Menu',
        darkModeSwitchLabel: 'Appearance',
        langMenuLabel: 'Language'
      }
    }
  },
  themeConfig: {
    logo: '/images/icon.png',
    socialLinks: [
      { icon: 'github', link: repository }
    ],
    nav: [
      { text: '使用文档', link: '/guide/' },
      { text: 'Island', link: '/guide/island' },
      { text: '文件安全', link: '/guide/file-safety' },
      { text: '下载', link: `${repository}/releases/latest` }
    ],
    sidebar: {
      '/guide/': [
        {
          text: '开始使用',
          collapsed: false,
          items: [
            { text: '文档首页', link: '/guide/' },
            { text: '安装 OpenYoink', link: '/guide/install' },
            { text: '三分钟快速上手', link: '/guide/quick-start' }
          ]
        },
        {
          text: '日常使用',
          collapsed: false,
          items: [
            { text: '侧边暂存架', link: '/guide/classic-shelf' },
            { text: 'OpenYoink Island', link: '/guide/island' },
            { text: 'Island 模块', link: '/guide/island-modules' },
            { text: '快捷键', link: '/guide/shortcuts' }
          ]
        },
        {
          text: '安全与帮助',
          collapsed: false,
          items: [
            { text: '文件安全与隐私', link: '/guide/file-safety' },
            { text: '常见问题', link: '/guide/troubleshooting' }
          ]
        }
      ]
    },
    outline: { label: '本页目录' },
    docFooter: { prev: '上一篇', next: '下一篇' },
    lastUpdated: { text: '最后更新于' },
    returnToTopLabel: '返回顶部',
    sidebarMenuLabel: '菜单',
    darkModeSwitchLabel: '外观',
    langMenuLabel: '语言',
    footer: {
      message: 'OpenYoink 是独立的开源项目，与商业应用 Yoink 没有隶属关系。',
      copyright: 'MIT License · © 2026 OpenYoink contributors'
    },
    search: {
      provider: 'local',
      options: {
        locales: {
          root: {
            translations: {
              button: { buttonText: '搜索文档', buttonAriaLabel: '搜索文档' },
              modal: {
                noResultsText: '没有找到相关内容',
                resetButtonTitle: '清除搜索',
                footer: {
                  selectText: '选择',
                  navigateText: '切换',
                  closeText: '关闭'
                }
              }
            }
          },
          en: {
            translations: {
              button: { buttonText: 'Search', buttonAriaLabel: 'Search documentation' },
              modal: {
                noResultsText: 'No results found',
                resetButtonTitle: 'Reset search',
                footer: {
                  selectText: 'Select',
                  navigateText: 'Navigate',
                  closeText: 'Close'
                }
              }
            }
          }
        }
      }
    }
  }
})
