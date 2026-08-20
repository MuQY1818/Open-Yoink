import { defineConfig } from 'vitepress'

const repository = 'https://github.com/MuQY1818/OpenYoink'
const siteURL = 'https://muqy1818.github.io/OpenYoink/'
const rootDescription = '免费的开源 macOS 拖拽暂存架与灵动岛。跨窗口、Space 和全屏应用搬运文件、图片、文本与链接。'
const englishDescription = 'A free, open-source drag-and-drop shelf and Dynamic Island for macOS. Move files, images, text, and links across windows and Spaces.'
const socialImageURL = new URL('images/usage-demo-poster.jpg', siteURL).href

const structuredData = JSON.stringify({
  '@context': 'https://schema.org',
  '@graph': [
    {
      '@type': 'WebSite',
      '@id': `${siteURL}#website`,
      name: 'OpenYoink',
      url: siteURL,
      description: rootDescription,
      inLanguage: ['zh-CN', 'en-US']
    },
    {
      '@type': 'SoftwareApplication',
      '@id': `${siteURL}#application`,
      name: 'OpenYoink',
      alternateName: 'OpenYoink for macOS',
      url: siteURL,
      downloadUrl: `${repository}/releases/latest`,
      codeRepository: repository,
      applicationCategory: 'UtilitiesApplication',
      operatingSystem: 'macOS 15 or later',
      description: rootDescription,
      image: socialImageURL,
      screenshot: [
        new URL('screenshots/island-media.png', siteURL).href,
        new URL('screenshots/island-shelf.png', siteURL).href
      ],
      featureList: [
        'Drag-and-drop shelf for files, images, text, and links',
        'OpenYoink Island for Mac notch displays',
        'Local-first storage with no account or analytics',
        'Open-source under the MIT License'
      ],
      isAccessibleForFree: true,
      offers: {
        '@type': 'Offer',
        price: '0',
        priceCurrency: 'USD'
      },
      license: `${repository}/blob/main/LICENSE`
    }
  ]
})

function pageURL(relativePath: string) {
  const route = relativePath
    .replace(/(^|\/)index\.md$/, '$1')
    .replace(/\.md$/, '')

  return new URL(route, siteURL).href
}

const bilingualPages = new Set([
  'index.md',
  'guide/index.md',
  'guide/quick-start.md',
  'guide/file-safety.md',
  'guide/island.md',
  'guide/open-source-drag-shelf.md'
])

export default defineConfig({
  title: 'OpenYoink',
  description: rootDescription,
  lang: 'zh-CN',
  base: '/OpenYoink/',
  srcExclude: ['README.md'],
  appearance: 'force-dark',
  cleanUrls: true,
  lastUpdated: true,
  sitemap: {
    hostname: siteURL,
    transformItems: items => items.filter(item => !item.url.endsWith('/README'))
  },
  head: [
    ['link', { rel: 'icon', href: '/OpenYoink/images/icon.png' }],
    ['link', { rel: 'sitemap', type: 'application/xml', href: `${siteURL}sitemap.xml` }],
    ['meta', { name: 'theme-color', content: '#ffffff' }],
    ['meta', { name: 'robots', content: 'index, follow, max-image-preview:large, max-snippet:-1, max-video-preview:-1' }],
    ['meta', { name: 'author', content: 'OpenYoink contributors' }],
    ['meta', { property: 'og:site_name', content: 'OpenYoink' }],
    ['meta', { property: 'og:image', content: socialImageURL }],
    ['meta', { property: 'og:image:width', content: '1440' }],
    ['meta', { property: 'og:image:height', content: '810' }],
    ['meta', { property: 'og:image:alt', content: 'OpenYoink running on macOS' }],
    ['meta', { name: 'twitter:card', content: 'summary_large_image' }],
    ['meta', { name: 'twitter:image', content: socialImageURL }],
    ['script', { type: 'application/ld+json' }, structuredData]
  ],
  transformPageData(pageData) {
    const url = pageURL(pageData.relativePath)
    const isEnglish = pageData.relativePath.startsWith('en/')
    const isRootHome = pageData.relativePath === 'index.md'
    const isEnglishHome = pageData.relativePath === 'en/index.md'
    const title = isRootHome
      ? 'OpenYoink — 免费开源的 macOS 拖拽暂存架与灵动岛'
      : isEnglishHome
        ? 'OpenYoink — Free, open-source drag shelf and Dynamic Island for macOS'
        : `${pageData.title} | OpenYoink`
    const description = pageData.description || (isEnglish ? englishDescription : rootDescription)
    const localizedPath = isEnglish ? pageData.relativePath.slice(3) : pageData.relativePath
    const breadcrumbItems = [
      {
        '@type': 'ListItem',
        position: 1,
        name: 'OpenYoink',
        item: isEnglish ? pageURL('en/index.md') : pageURL('index.md')
      }
    ]

    if (localizedPath.startsWith('guide/')) {
      breadcrumbItems.push({
        '@type': 'ListItem',
        position: 2,
        name: isEnglish ? 'Guide' : '使用文档',
        item: isEnglish ? pageURL('en/guide/index.md') : pageURL('guide/index.md')
      })
    }

    if (!localizedPath.endsWith('index.md')) {
      breadcrumbItems.push({
        '@type': 'ListItem',
        position: breadcrumbItems.length + 1,
        name: pageData.title,
        item: url
      })
    }

    pageData.frontmatter.head ??= []
    pageData.frontmatter.head.push(
      ['link', { rel: 'canonical', href: url }],
      ['meta', { property: 'og:url', content: url }],
      ['meta', { property: 'og:title', content: title }],
      ['meta', { property: 'og:description', content: description }],
      ['meta', { property: 'og:type', content: 'website' }],
      ['meta', { property: 'og:locale', content: isEnglish ? 'en_US' : 'zh_CN' }],
      ['meta', { name: 'twitter:title', content: title }],
      ['meta', { name: 'twitter:description', content: description }],
      ['script', { type: 'application/ld+json' }, JSON.stringify({
        '@context': 'https://schema.org',
        '@type': 'BreadcrumbList',
        itemListElement: breadcrumbItems
      })]
    )

    if (bilingualPages.has(localizedPath)) {
      const chineseURL = pageURL(localizedPath)
      const englishURL = pageURL(`en/${localizedPath}`)
      pageData.frontmatter.head.push(
        ['link', { rel: 'alternate', hreflang: 'zh-CN', href: chineseURL }],
        ['link', { rel: 'alternate', hreflang: 'en-US', href: englishURL }],
        ['link', { rel: 'alternate', hreflang: 'x-default', href: chineseURL }],
        ['meta', { property: 'og:locale:alternate', content: isEnglish ? 'zh_CN' : 'en_US' }]
      )
    }
  },
  locales: {
    root: {
      label: '简体中文',
      lang: 'zh-CN',
      title: 'OpenYoink',
      description: rootDescription
    },
    en: {
      label: 'English',
      lang: 'en-US',
      title: 'OpenYoink',
      description: englishDescription,
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
                { text: 'Why OpenYoink', link: '/en/guide/open-source-drag-shelf' },
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
            { text: '三分钟快速上手', link: '/guide/quick-start' },
            { text: '为什么选择 OpenYoink', link: '/guide/open-source-drag-shelf' }
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
