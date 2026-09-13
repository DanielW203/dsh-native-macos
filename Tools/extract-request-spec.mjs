#!/usr/bin/env node
/**
 * M0 spec extraction: pull the exact model-visible request specification out of
 * a recorded session log.
 *
 * A `request/header` event records what the runtime actually sent the model:
 * `data.header.system` is the rendered system prompt and `data.header.tools` is
 * the exact tool schema array. Those two are the conformance baseline for the
 * Swift reimplementation, so they are extracted verbatim rather than restated.
 *
 * Usage: node Tools/extract-request-spec.mjs <session.jsonl.zstd> <outDir>
 */
import { createInterface } from 'node:readline'
import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const [file, outDir] = process.argv.slice(2)
if (file === undefined || outDir === undefined || !existsSync(file)) {
  console.error('usage: node Tools/extract-request-spec.mjs <session.jsonl.zstd> <outDir>')
  process.exit(2)
}
mkdirSync(outDir, { recursive: true })

let system = null
let tools = null
let headerConfig = null
let sessionId = null
let headerSeen = 0

const zstd = spawn('zstd', ['-d', '-c', file], { stdio: ['ignore', 'pipe', 'ignore'] })
const rl = createInterface({ input: zstd.stdout, crlfDelay: Infinity })
rl.on('line', line => {
  if (line === '') return
  let event
  try { event = JSON.parse(line) } catch { return }
  if (event.type === 'session' && sessionId === null) sessionId = event.id
  if (event.type !== 'request/header') return
  headerSeen += 1
  const header = event.data?.header
  if (header === null || typeof header !== 'object') return
  // The first header carries the full prompt; later turns re-send a prefix.
  if (system === null && typeof header.system === 'string') system = header.system
  if (tools === null && Array.isArray(header.tools)) tools = header.tools
  headerConfig ??= header.config ?? null
})

rl.on('close', () => {
  if (system === null || tools === null) {
    console.error('no complete request/header found (' + String(headerSeen) + ' headers seen)')
    process.exit(1)
  }
  writeFileSync(join(outDir, 'system-prompt.txt'), system.endsWith('\n') ? system : system + '\n')
  writeFileSync(join(outDir, 'tools.schemas.json'), JSON.stringify(tools, null, 2) + '\n')
  writeFileSync(join(outDir, 'request-header.meta.json'), JSON.stringify({
    sourceSession: sessionId,
    headersObserved: headerSeen,
    systemPromptChars: system.length,
    toolCount: tools.length,
    config: headerConfig,
  }, null, 2) + '\n')
  console.log('system prompt: ' + String(system.length) + ' chars')
  console.log('tools: ' + String(tools.length))
  console.log('names: ' + tools.map(t => t.name).join(', '))
})
