#!/usr/bin/env node
/**
 * M0 spec extraction: report the nested payload structure of every session
 * event type. Prints key names and JSON value kinds — never field values, so
 * the output is a schema, not a transcript.
 *
 * Usage: node Tools/extract-schema.mjs <session.jsonl.zstd> [outFile]
 */
import { createInterface } from 'node:readline'
import { spawn } from 'node:child_process'
import { existsSync, writeFileSync } from 'node:fs'

const file = process.argv[2]
if (file === undefined || !existsSync(file)) {
  console.error('usage: node Tools/extract-schema.mjs <session.jsonl.zstd> [outFile]')
  process.exit(2)
}

/** Describe a value as a stable JSON kind, or as the observed scalar domain. */
function kind(value, observed) {
  if (value === null) return 'null'
  if (Array.isArray(value)) return 'array'
  if (typeof value === 'object') return 'object'
  const t = typeof value
  if (t === 'string' || t === 'number' || t === 'boolean') {
    if (observed !== undefined) observed.add(t)
    return t
  }
  return t
}

/** Fold one payload into a structural description keyed by member name. */
function describe(value, node, depth) {
  if (depth > 6) return
  if (Array.isArray(value)) {
    node.itemKinds ??= new Set()
    for (const item of value.slice(0, 20)) node.itemKinds.add(kind(item))
    const first = value.find(v => v !== null && typeof v === 'object' && !Array.isArray(v))
    if (first !== undefined) describe(first, node.item ??= {}, depth + 1)
    return
  }
  if (value === null || typeof value !== 'object') return
  node.members ??= {}
  for (const [key, child] of Object.entries(value)) {
    const entry = node.members[key] ??= { kinds: new Set() }
    entry.kinds.add(kind(child))
    describe(child, entry, depth + 1)
  }
}

/** Convert Sets to sorted arrays for JSON output. */
function freeze(node) {
  if (node === null || typeof node !== 'object') return node
  if (node instanceof Set) return [...node].sort()
  const out = {}
  for (const key of Object.keys(node).sort()) out[key] = freeze(node[key])
  return out
}

const zstd = spawn('zstd', ['-d', '-c', file], { stdio: ['ignore', 'pipe', 'ignore'] })
const byType = new Map()

const rl = createInterface({ input: zstd.stdout, crlfDelay: Infinity })
rl.on('line', line => {
  if (line === '') return
  let event
  try { event = JSON.parse(line) } catch { return }
  const type = event.type ?? '(no type)'
  const node = byType.get(type) ?? { count: 0 }
  byType.set(type, node)
  node.count += 1
  node.envelope ??= { members: {} }
  for (const [key, child] of Object.entries(event)) {
    if (key === 'data') continue
    const entry = node.envelope.members[key] ??= { kinds: new Set() }
    entry.kinds.add(kind(child))
  }
  if ('data' in event) describe(event.data, node.data ??= {}, 0)
})

rl.on('close', () => {
  const out = {}
  for (const [type, node] of [...byType].sort((a, b) => a[0].localeCompare(b[0]))) {
    out[type] = { count: node.count, envelope: freeze(node.envelope), data: freeze(node.data) }
  }
  const text = JSON.stringify(out, null, 2)
  const target = process.argv[3]
  if (target !== undefined) { writeFileSync(target, text + '\n'); console.log('wrote ' + target) }
  else console.log(text)
})
