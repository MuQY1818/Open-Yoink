import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'

const distURL = new URL('../.vitepress/dist/', import.meta.url)

function fail(message) {
  throw new Error(`SEO validation failed: ${message}`)
}

async function read(relativePath) {
  return readFile(new URL(relativePath, distURL), 'utf8')
}

function expectIncludes(content, expected, label) {
  if (!content.includes(expected)) {
    fail(`${label} is missing ${expected}`)
  }
}

function validateJSONLD(html, label) {
  const blocks = [...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)]
  if (blocks.length === 0) fail(`${label} has no JSON-LD`)

  for (const [, json] of blocks) {
    JSON.parse(json)
  }
}

const pages = [
  {
    file: 'index.html',
    canonical: 'https://muqy1818.github.io/OpenYoink/',
    title: 'OpenYoink — 免费开源的 macOS 拖拽暂存架与灵动岛'
  },
  {
    file: 'en/index.html',
    canonical: 'https://muqy1818.github.io/OpenYoink/en/',
    title: 'OpenYoink — Free, open-source drag shelf and Dynamic Island for macOS'
  },
  {
    file: 'guide/open-source-drag-shelf.html',
    canonical: 'https://muqy1818.github.io/OpenYoink/guide/open-source-drag-shelf',
    title: '免费开源的 macOS 拖拽暂存架 | OpenYoink'
  },
  {
    file: 'en/guide/open-source-drag-shelf.html',
    canonical: 'https://muqy1818.github.io/OpenYoink/en/guide/open-source-drag-shelf',
    title: 'A free, open-source drag shelf for macOS | OpenYoink'
  }
]

for (const page of pages) {
  const html = await read(page.file)
  expectIncludes(html, `<title>${page.title}</title>`, page.file)
  expectIncludes(html, `rel="canonical" href="${page.canonical}"`, page.file)
  expectIncludes(html, 'name="robots" content="index, follow, max-image-preview:large', page.file)
  expectIncludes(html, 'property="og:url"', page.file)
  expectIncludes(html, 'property="og:title"', page.file)
  expectIncludes(html, 'property="og:description"', page.file)
  expectIncludes(html, 'name="twitter:card" content="summary_large_image"', page.file)
  expectIncludes(html, 'rel="alternate" hreflang="zh-CN"', page.file)
  expectIncludes(html, 'rel="alternate" hreflang="en-US"', page.file)
  validateJSONLD(html, page.file)
}

const homepage = await read('index.html')
expectIncludes(homepage, '"@type":"SoftwareApplication"', 'homepage')
expectIncludes(homepage, '免费的开源 macOS 拖拽暂存架', 'homepage content')

const sitemap = await read('sitemap.xml')
expectIncludes(sitemap, '<loc>https://muqy1818.github.io/OpenYoink/</loc>', 'sitemap')
expectIncludes(sitemap, '<loc>https://muqy1818.github.io/OpenYoink/guide/open-source-drag-shelf</loc>', 'sitemap')
expectIncludes(sitemap, '<loc>https://muqy1818.github.io/OpenYoink/en/guide/open-source-drag-shelf</loc>', 'sitemap')
if (sitemap.includes('/README')) fail('sitemap exposes the internal website README')

console.log(`SEO validation passed for ${pages.length} representative pages in ${fileURLToPath(distURL)}`)
