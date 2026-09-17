# NOTICE

本文件说明本仓库（NativeHarness / DSH Native）与第三方项目的归属关系。
**本仓库是独立的非官方第三方客户端，与 DeepSeek 官方无任何隶属、赞助或背书关系。**

## 上游项目

- **DeepSeek Harness** 与其 npm 包 **`@deepseek-ai/dsh`** **不包含在本仓库中**。
  本 App 在运行时会从 `registry.npmjs.org` 下载并运行它，其源代码、许可与使用条款
  以官方发布为准（官方仓库的 `package.json` 标注为 MIT）。
- “DeepSeek”、“DeepSeek Harness” 及相关名称、标识归其各自权利人所有。
  本仓库对其的使用仅为**指明兼容的上游系统**（nominative use），不代表任何形式的关联。

## 本仓库内容

- 除下列例外，本仓库源码以 [MIT](LICENSE) 发布，版权归 NativeHarness contributors。

## 随仓库分发的第三方代码

| 路径 | 项目 | 许可 |
|---|---|---|
| `Vendor/zstd/**` | Zstandard (facebook/zstd) | BSD-3-Clause OR GPL-2.0（本项目按 BSD-3-Clause 使用）；见 `Vendor/zstd/LICENSE`、`Vendor/zstd/COPYING` |

## 派生规范文件（Derived specification files）

下列文件包含派生自官方 DeepSeek Harness 的内容，按同样的 MIT 条款再分发，并在此声明归属：

- `Spec/**` —— 从官方运行时提取的规范 fixture
- `Sources/HarnessCore/Tools/Generated/ToolSchemas.swift` —— 由官方工具目录生成

The following files contain material derived from the official DeepSeek Harness
(`@deepseek-ai/dsh`, MIT License, Copyright (c) 2026 DeepSeek) and are redistributed
here under the same MIT terms with this attribution. (This attribution lives here rather
than in `LICENSE`: `LICENSE` must stay verbatim MIT so that GitHub's license detection
reports MIT instead of NOASSERTION.)

## 素材与品牌

- `Apps/DSHNative/Resources/Assets.xcassets/AppIcon.appiconset/` 内的应用图标**包含 DeepSeek
  的品牌标识（鲸鱼图形与飞鸟图形）**。该图标**不随本仓库的 MIT 许可授权**，其商标权与
  版权归权利人所有。
- 维护者已知悉该图标的使用存在商标/版权风险，并选择按现状分发、自行承担该风险。
  若权利人提出异议，维护者将立即替换为不含品牌元素的图标。
- 除上述应用图标外，仓库内不含官方商标素材；如有遗漏，请提 issue 告知，我们会移除。

## 运行时数据

本 App 不向本仓库写入任何用户数据。运行时树默认位于 `~/.nativeharness`（可用
`NATIVE_HARNESS_ROOT` 覆盖），其中包含 profiles、sessions、settings 与 credentials，
均属用户本地数据，不在版本控制范围内。
