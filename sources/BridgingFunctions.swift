//
//  BridgingFunctions.swift
//  Squirrel
//
//  Created by Leo Liu on 5/11/24.
//
//  HengIME 换血：数据源从 librime rime_api 换为 heng_core C ABI。
//  本文件保留与数据源无关的通用助手，并新增 heng_* 的 Swift 便捷封装。
//

import Foundation

/// heng_session_t（uint64_t）。0 表示无效会话。
typealias RimeSessionId = UInt64

// MARK: - heng_* 便捷封装

/// 读取会话选项（heng_get_option）。
func hengGetOption(_ session: RimeSessionId, _ option: String) -> Bool {
  guard session != 0 else { return false }
  return option.withCString { heng_get_option(session, $0) != 0 }
}

/// 设置会话选项（heng_set_option；传播/持久化策略由 core 统一处理）。
func hengSetOption(_ session: RimeSessionId, _ option: String, _ value: Bool) {
  guard session != 0 else { return }
  _ = option.withCString { heng_set_option(session, $0, value ? 1 : 0) }
}

/// 上报 inline_preedit 开关给 core（heng_set_inline_preedit）。仅 macOS 有效。
func hengSetInlinePreedit(_ on: Bool) {
  heng_set_inline_preedit(on ? 1 : 0)
}

/// 读 weasel.custom.yaml 的 style/<key>（heng_style_flag，源补丁直读，不过部署缓存）。
/// 返回调用方传入的 defaultValue = 键不存在（无覆盖）；0/1 = 有显式值。
func hengStyleFlag(_ key: String, _ defaultValue: Int32) -> Int32 {
  return key.withCString { heng_style_flag($0, defaultValue) }
}

/// 取待上屏文本（消费语义）。
func hengTakeCommit(_ session: RimeSessionId) -> String? {
  guard session != 0 else { return nil }
  var ptr: UnsafeMutablePointer<CChar>?
  guard heng_commit_text(session, &ptr) != 0, let text = ptr else { return nil }
  defer { heng_free_string(text) }
  return String(cString: text)
}

/// 取「鼠标点选候选」产生的上屏文本（消费语义）。
///
/// 与 hengTakeCommit 分开：按键路径的 commit 由 rimeUpdate 开头统一取，
/// 而点选候选没有任何按键事件伴随，必须在点击处理里显式取一次，
/// 否则候选窗关了但字不上屏。
func hengTakeUiCommit(_ session: RimeSessionId) -> String? {
  guard session != 0 else { return nil }
  var ptr: UnsafeMutablePointer<CChar>?
  guard heng_take_ui_commit(session, &ptr) != 0, let text = ptr else { return nil }
  defer { heng_free_string(text) }
  return String(cString: text)
}

/// 取组合串原始输入（如拼音串）。nil = 无组合。
func hengGetInput(_ session: RimeSessionId) -> String? {
  guard session != 0 else { return nil }
  var ptr: UnsafeMutablePointer<CChar>?
  guard heng_get_input(session, &ptr) != 0, let text = ptr else { return nil }
  defer { heng_free_string(text) }
  return String(cString: text)
}

/// 选项状态标签（短/长），菜单栏图标与浮窗用。nil = 无标签。
func hengStateLabel(_ session: RimeSessionId, _ option: String, _ state: Bool, abbreviated: Bool) -> String? {
  guard session != 0 else { return nil }
  var buf = [CChar](repeating: 0, count: 256)
  let rc = option.withCString {
    heng_get_state_label_abbreviated(session, $0, state ? 1 : 0, abbreviated ? 1 : 0, &buf, Int32(buf.count))
  }
  guard rc > 0, rc < Int32(buf.count) else { return nil }
  return String(cString: buf)
}

/// 把 UTF-8 字节偏移安全映射为 String.Index（越界收敛到边界）。
func stringIndex(utf8Offset offset: Int, in string: String) -> String.Index {
  let limit = string.utf8.index(string.utf8.startIndex, offsetBy: offset, limitedBy: string.utf8.endIndex) ?? string.utf8.endIndex
  return String.Index(limit, within: string) ?? string.endIndex
}

// MARK: - 通用助手

infix operator ?= : AssignmentPrecedence
// swiftlint:disable:next operator_whitespace
func ?=<T>(left: inout T, right: T?) {
  if let right = right {
    left = right
  }
}
// swiftlint:disable:next operator_whitespace
func ?=<T>(left: inout T?, right: T?) {
  if let right = right {
    left = right
  }
}

extension NSRange {
  static let empty = NSRange(location: NSNotFound, length: 0)
}

extension NSPoint {
  static func += (lhs: inout Self, rhs: Self) {
    lhs.x += rhs.x
    lhs.y += rhs.y
  }
  static func - (lhs: Self, rhs: Self) -> Self {
    Self.init(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
  }
  static func -= (lhs: inout Self, rhs: Self) {
    lhs.x -= rhs.x
    lhs.y -= rhs.y
  }
  static func * (lhs: Self, rhs: CGFloat) -> Self {
    Self.init(x: lhs.x * rhs, y: lhs.y * rhs)
  }
  static func / (lhs: Self, rhs: CGFloat) -> Self {
    Self.init(x: lhs.x / rhs, y: lhs.y / rhs)
  }
  var length: CGFloat {
    sqrt(pow(self.x, 2) + pow(self.y, 2))
  }
}

// MARK: - 上屏回调（点击选词）

/// core 选词完成后回调这个 C 函数（经 heng_set_commit_handler 注册）。
///
/// 为什么必须用回调而不是轮询：点击事件从 Swift 主线程发给 core UI 线程，
/// core 要跨两轮循环（poll_events 收点击 → 下一轮 try_recv 才拿到 BarSelect）
/// 才处理完并产出 commit，实测比主线程的下一轮**晚约 9ms**。
/// 外壳在 mouseUp 里 DispatchQueue.main.async 取的话必定取空
/// —— 实测 takeUiCommit 返回 nil，而 9ms 后 map 里才出现文本。
/// 回调则由 core 在文本就绪的同一刻发起，时序天然正确。
private let commitCallback: @convention(c) (UnsafeMutableRawPointer?, UInt64, UnsafePointer<CChar>?) -> Void = {
  _, session, text in
  guard let text else { return }
  let s = String(cString: text)
  // 带上会话句柄：工具窗（表情/符号）的上屏可能投给「最近用过的会话」，
  // 而同一进程里每个宿主都挂着一个 controller。只有 session 相符的那个
  // 才该把字插进自己的 client，否则一次点击会往多个应用里各插一份。
  DispatchQueue.main.async {
    NotificationCenter.default.post(
      name: .hengCoreCommitReady, object: nil,
      userInfo: ["text": s, "session": session])
  }
}

extension Notification.Name {
  static let hengCoreCommitReady = Notification.Name("HengCoreCommitReady")
}

/// 注册上屏回调（进程级，只需一次）。幂等。
func hengRegisterCommitHandler() {
  heng_set_commit_handler(commitCallback, nil)
}
