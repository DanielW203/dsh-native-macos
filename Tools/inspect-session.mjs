#!/usr/bin/env node
/**
 * M0 spec extraction: report the structure of a DSH session log.
 *
 * Reads a session.jsonl.zstd (a concatenation of independent zstd frames, one
 * per append) and prints the event vocabulary and envelope members. It prints
 * structure only — never message content.
 *
 * Usage: node Tools/inspect-session.mjs <session.jsonl.zstd>
 */
import { createInterface } from 'node:readline'
import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'

const file = process.argv[2]
if (file === undefined || !existsSync(file)) {
  console.error('usage: node Tools/inspect-session.mjs <session.jsonl.zstd>')
  process.exit(2)
}

// Node's zstd decompressor stops at the first frame and the log is many frames,
// so the zstd CLI (which concatenates frames natively) owns decompression.
const zstd = spawn('zstd', ['-d', '-c', file], { stdio: ['ignore', 'pipe', 'ignore'] })

const hist = new Map()
const keys = new Map()
let total = 0

const rl = createInterface({ input: zstd.stdout, crlfDelay: Infinity })
rl.on('line', line => {
  if (line === '') return
  let event
  try { event = JSON.parse(line) } catch { return }
  total += 1
  const type = event.type ?? '(no type)'
  hist.set(type, (hist.get(type) ?? 0) + 1)
  if (!keys.has(type)) keys.set(type, new Set())
  for (const key of Object.keys(event)) keys.get(type).add(key)
})

rl.on('close', () => {
  console.log('events: ' + String(total) + '  distinct types: ' + String(hist.size))
  console.log('--- histogram ---')
  for (const [type, count] of [...hist].sort((a, b) => b[1] - a[1])) {
    console.log(String(count).padStart(7) + '  ' + type)
  }
  console.log('--- keys per type ---')
  for (const [type, set] of keys) console.log(type + ' => ' + [...set].join(','))
})
