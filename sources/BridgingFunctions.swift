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
  return option.withCString { heng_get_option(session, $0) } != 0
}

/// 设置会话选项（heng_set_option；传播/持久化策略由 core 统一处理）。
func hengSetOption(_ session: RimeSessionId, _ option: String, _ value: Bool) {
  guard session != 0 else { return }
  option.withCString { heng_set_option(session, $0, value ? 1 : 0) }
}

/// 取待上屏文本（消费语义）。
func hengTakeCommit(_ session: RimeSessionId) -> String? {
  guard session != 0 else { return nil }
  var ptr: UnsafeMutablePointer<CChar>?
  guard heng_commit_text(session, &ptr) != 0, let text = ptr else { return nil }
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
