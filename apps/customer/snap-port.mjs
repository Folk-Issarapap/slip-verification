import { chromium } from "@playwright/test"

// usage: node snap.mjs <pattern-id> <live-slug>
// e.g.: node snap.mjs pattern-list-page list-default
const refId = process.argv[2]
const liveSlug = process.argv[3]
const refOut = `/tmp/ref-${liveSlug}.png`
const liveOut = `/tmp/live-${liveSlug}.png`

const browser = await chromium.launch()

// Reference: scroll-to-id, clip to section bounds
{
  const page = await (await browser.newContext({ viewport: { width: 1280, height: 800 } })).newPage()
  await page.goto("http://localhost:8000/Bro%20Pay%20Design%20System.html", { waitUntil: "networkidle" })
  await page.waitForTimeout(2000)
  const box = await page.evaluate(id => {
    const el = document.getElementById(id)
    if (!el) return null
    const r = el.getBoundingClientRect()
    return { top: r.top + window.scrollY, height: r.height }
  }, refId)
  if (box) {
    const h = Math.min(Math.ceil(box.height), 1900)
    await page.setViewportSize({ width: 1280, height: h })
    await page.evaluate(t => window.scrollTo(0, t), box.top)
    await page.waitForTimeout(400)
    await page.screenshot({ path: refOut, clip: { x: 0, y: 0, width: 1280, height: h } })
    console.log(`ref ${refId} → ${refOut} (h=${h})`)
  } else {
    console.log(`MISSING ref section: ${refId}`)
  }
  await page.close()
}

// Live: full page screenshot at 1280×1600
{
  const page = await (await browser.newContext({ viewport: { width: 1280, height: 1600 } })).newPage()
  await page.goto(`http://localhost:3004/patterns/${liveSlug}`, { waitUntil: "networkidle" })
  await page.waitForTimeout(1500)
  await page.screenshot({ path: liveOut, fullPage: true })
  console.log(`live /patterns/${liveSlug} → ${liveOut}`)
  await page.close()
}

await browser.close()
