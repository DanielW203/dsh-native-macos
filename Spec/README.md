# Spec/ — 规格基准（fixtures）

这个目录存放**从真实运行的官方 DeepSeek Harness 提取出来的规格快照**，用途是
给 `Sources/HarnessCore`（用 Swift 复刻的那条路线）当**对齐基准**。

它**不是构建依赖**：`Package.swift` 不引用本目录，各模块的测试只读自己的
`Tests/*/Fixtures/`。删掉它不影响任何人构建或跑测试——它只是"官方到底发了什么"
的原始证据，避免复刻时凭记忆写。

| 文件 | 内容 | 生成脚本（维护者侧） |
|---|---|---|
| `tools.schemas.json` | 一次真实请求里模型看到的工具 JSON Schema（默认 profile，25 个工具） | `Tools/extract-request-spec.mjs` |
| `system-prompt.txt` | 同一次请求渲染出来的 system prompt 全文 | 同上 |
| `request-header.meta.json` | 该次请求的元数据（会话 id、模型、工具数） | 同上 |
| `current-profile/*` | 上面三件套，但取自维护者当前 profile（含插件） | 同上 |
| `session-v3/event-schema.json` | 会话文件 `session.jsonl.zstd` 的事件格式 | `Tools/inspect-session.mjs` |
| `tool-catalog.schemas.json` | 官方工具目录（58 个工具） | `Tools/extract-tool-catalog.mjs` |

> 上表「生成脚本」一列里那些 `Tools/*.mjs` 只存在于维护者的源目录，**不在公开发布副本里**。
> 读公开副本时不必去找它们：它们是快照的出处，不是使用本目录所需的工具。

## 重新生成

需要一份本机可运行的官方 harness（能产出会话日志）以及 Node.js。以下命令在**维护者的源目录**里执行：

```bash
# 从一个会话日志里提取「模型实际收到了什么」
node Tools/extract-request-spec.mjs <session.jsonl.zstd> Spec

# 只查看会话日志的结构（不打印消息内容）
node Tools/inspect-session.mjs <session.jsonl.zstd>

# 从官方工具目录文档提取机器可读的工具 schema
node Tools/extract-tool-catalog.mjs <官方仓库>/docs/tool-catalog.md Spec/tool-catalog.schemas.json
```

会话日志默认位于 `$DSH_HOME/sessions/<转义后的 cwd>/session-<uuid>/session.jsonl.zstd`。

## 发布说明

本目录下的 `system-prompt.txt` 与 `request-header.meta.json` **不随公开发布**——前者是
官方提示词全文且包含维护者的本机路径，后者包含本机会话 id。导出发布副本的流程会自动
把它们挡在外面。

上面提到的几个提取/生成脚本同样是维护者侧工具，**不随公开发布**：它们只存在于维护者的
源目录里，公开副本不带。公开副本里保留的是这些提取结果的快照本身——它们才是对齐基准。

保留下来的 schema 类文件属于从官方 DeepSeek Harness（`@deepseek-ai/dsh`，MIT License，
Copyright (c) 2026 DeepSeek）提取的衍生内容，归属声明见仓库根目录 `LICENSE`
的 "Derived specification files" 一节。
