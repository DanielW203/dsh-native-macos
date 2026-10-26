import Foundation

/// Every way a skills operation can fail.
///
/// One type rather than a thrown `NSError`: the window has exactly one place to show a
/// failure, and these strings *are* that UI text. The cases a caller branches on — a taken
/// name, a linked skill, an entry that moved under the panel — are enumerated here so the
/// decision is never made by matching on a message.
public enum SkillCenterError: Error, LocalizedError, Equatable, Sendable {
  /// The name is not kebab-case, or is empty. Mirrors the official `isSkillName` grammar.
  case invalidName(String)
  case emptyDescription
  case emptyContent
  /// The create form's content cap, mirroring the Web plugin's 64 KiB body limit.
  case contentTooLarge(bytes: Int, limit: Int)
  /// The file has no `---` frontmatter block, so it cannot be edited as a skill.
  case missingFrontmatter(String)
  /// A skill was named for an operation but no longer resolves to that exact path.
  case pathChanged(String)
  case noSkillFound(String)
  case nameTaken(String, at: String)
  case entryOccupied(String)
  /// Symlinked skills cannot be deleted: the move would take the link target's file with it.
  case linkedSkill(String)
  /// An import source that holds no usable SKILL.md, with the frontmatter's own complaint.
  case sourceNotSkill(path: String, reason: String)
  case trashMissing(String)
  case commandFailed(label: String, status: Int32, message: String)
  case fileSystem(String)

  public var errorDescription: String? {
    switch self {
    case .invalidName(let name):
      return "「\(name)」不是合法的技能名：只允许小写字母、数字和单个连字符，且首尾不能是连字符。"
    case .emptyDescription:
      return "描述不能为空：官方注册表用描述决定这个技能是否被模型看到。"
    case .emptyContent:
      return "技能正文不能为空。"
    case .contentTooLarge(let bytes, let limit):
      return "技能正文 \(bytes) 字节，超过 \(limit) 字节上限。"
    case .missingFrontmatter(let path):
      return "\(path) 没有 frontmatter（缺少开头的 `---` 块），无法作为技能改写。"
    case .pathChanged(let name):
      return "技能「\(name)」的位置已经变了，请刷新后重试。"
    case .noSkillFound(let name):
      return "找不到技能「\(name)」。"
    case .nameTaken(let name, let path):
      return "技能「\(name)」已存在：\(path)"
    case .entryOccupied(let path):
      return "目标位置已被占用：\(path)"
    case .linkedSkill(let name):
      return "技能「\(name)」是符号链接，删除会动到链接目标，因此拒绝执行；请直接在 Finder 里处理这个链接。"
    case .sourceNotSkill(let path, let reason):
      return "\(path) 不是一个可导入的技能：\(reason)"
    case .trashMissing(let path):
      return "回收站条目已不存在：\(path)"
    case .commandFailed(let label, let status, let message):
      let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
      return detail.isEmpty ? "\(label) 失败（退出码 \(status)）" : "\(label) 失败（退出码 \(status)）：\(detail)"
    case .fileSystem(let message):
      return message
    }
  }

  /// Whether the message belongs beside the name field of the create form.
  public var isNameFieldError: Bool {
    switch self {
    case .invalidName, .emptyDescription, .emptyContent, .contentTooLarge, .nameTaken:
      return true
    default:
      return false
    }
  }
}
