//
//  HengWindowRenderer.swift
//  Squirrel
//
//  HengIME M-P4：macOS 窗口后端的外壳侧。
//
//  为什么这一层存在：
//  core 只负责 slint 渲染（算出「这一帧长什么样」），窗口的创建/定位/贴帧交给
//  外壳在**主线程**执行。原因：AppKit 的窗口调用必须在主线程，而 core 的 UI 线程
//  是它自己 spawn 的 Rust 线程，直接碰 NSPanel 会崩或无响应。
//  这一层就是那「最后一公里」—— 而且外壳本来就知道 macOS 的窗口长什么样。
//
//  三个关键点：
//  1. 透明：NSPanel 默认 opaque，会刷一层系统灰底 → 圆角外变黑方块。
//     必须 opaque=NO + backgroundColor=clear + hasShadow=NO。
//  2. 不抢焦点：候选窗/字母区用 .nonactivatingPanel，显示与点击都不夺用户焦点
//     （否则候选窗一弹出，用户正在编辑的应用就被踢失焦）。设置窗不加，可激活。
//  3. 坐标系：core 三端统一传**左上原点**（X11 原生如此，Win 在后端里翻），
//     AppKit 是**左下原点**，这里翻：y_flipped = screenH - (y + h)。
//     漏翻会让窗口出现在屏幕垂直镜像的位置。
//

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

final class HengWindowRenderer: NSObject {
  static let shared = HengWindowRenderer()

  ///窗口编号，与 core 的 win 参数一一对应
  private enum Win: Int {
    case candidate = 0   // 候选窗
    case settings = 1   // 设置窗口
    case letters = 2    // 顶部字母区
    case tools = 3      // 符号窗口（长驻、nonactivating）
    case emoji = 4      // 表情窗口（长驻、nonactivating，与符号窗独立）
    case vkbd = 5       // 软键盘（长驻、nonactivating）
  }

  /// 操作类型，与 core 的 op 参数一一对应
  private enum Op {
    static let configure = 0
    static let show = 1
    static let hide = 2
    static let blit = 3
    static let beginDrag = 4
  }

  /// 窗口池。惰性创建 —— 候选窗先到，设置窗按需。
  private var panels: [Int: NSPanel] = [:]
  /// 承载帧的视图（与 panels 同生命周期）
  private var layers: [Int: CALayer] = [:]
  /// 各窗口当前尺寸，拖动带的 × 排除区要用
  private var sizes: [Int: NSSize] = [:]
  /// 设置窗拖动基准：(拖起时窗口原点, 拖起时指针屏幕坐标)
  private var dragStart: (origin: NSPoint, pointer: NSPoint)?
  /// 主屏高度（左上↔左下翻转要用）
  private lazy var screenHeight: CGFloat = {
    NSScreen.screens.first?.frame.height ?? 1080
  }()
  /// 主屏 backingScaleFactor：core 的几何/帧都是设备像素，AppKit 用点，换算靠它。
  private lazy var screenScale: CGFloat = {
    NSScreen.screens.first?.backingScaleFactor ?? 1
  }()

  private override init() {
    super.init()
  }

  // MARK: - 注册到 core

  /// 供 SquirrelApplicationDelegate.startRime 调用。
  @discardableResult
  func register() -> Int32 {
    // 先把屏幕信息喂给 core：AppKit 只能在主线程查，而这必须在
    // core 布局设置窗之前就绪。
    reportScreenInfo()
    let ctx = Unmanaged.passUnretained(self).toOpaque()
    let rc = heng_set_window_handler({ ctx, win, op, buf, bufLen, logicalW, logicalH in
      guard let ctx else { return }
      let renderer = Unmanaged<HengWindowRenderer>.fromOpaque(ctx).takeUnretainedValue()
      renderer.handle(win: win, op: op, buf: buf, bufLen: bufLen, logicalW: logicalW, logicalH: logicalH)
    }, ctx)
    Self.log("REGISTER window=\(rc > 0)")
    return rc
  }

  /// 诊断日志落盘。输入法进程由系统按需拉起，stdout 拿不到，
  /// 只能写文件。路径放 ~/Library/Logs/HengIME/。
  private static let logURL: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/HengIME", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("window.log")
  }()

  /// 日志上限：超过就把当前文件滚成 window.log.1（覆盖上一份），只留两份。
  /// 输入法常驻，逐键日志每天几千行，不设上限会无限增长。
  /// 用**累计字节数**判断而不是「启动时查一次」：进程可能连续跑几周，
  /// 只在启动时判断等于运行期间永不轮转。
  private static let logMaxBytes = 2 * 1024 * 1024
  private static var logBytes = -1          // -1 = 尚未 stat
  /// 句柄常驻：原来每写一行都 open/close 一次，逐键路径上三次系统调用没必要。
  private static var logHandle: FileHandle?
  private static let logLock = NSLock()

  static func log(_ s: String) {
    logLock.lock()
    defer { logLock.unlock() }
    let data = Data("\(Date().timeIntervalSince1970) \(s)\n".utf8)
    if logBytes < 0 { logBytes = currentLogSize() }
    if logBytes > logMaxBytes { rotateLog() }
    if logHandle == nil {
      if !FileManager.default.fileExists(atPath: logURL.path) {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
      }
      logHandle = FileHandle(forWritingAtPath: logURL.path)
      logHandle?.seekToEndOfFile()
    }
    logHandle?.write(data)
    logBytes += data.count
  }

  private static func currentLogSize() -> Int {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
          let size = attrs[.size] as? Int else { return 0 }
    return size
  }

  private static func rotateLog() {
    try? logHandle?.close()
    logHandle = nil
    let old = logURL.deletingPathExtension().appendingPathExtension("log.1")
    try? FileManager.default.removeItem(at: old)
    try? FileManager.default.moveItem(at: logURL, to: old)
    logBytes = 0
  }

  /// 调试用：当前感知到的屏幕信息
  func debugScreenInfo() -> String {
    guard let s = NSScreen.screens.first else { return "无屏幕" }
    return "\(Int(s.frame.width))x\(Int(s.frame.height))@\(s.backingScaleFactor)x"
  }

  /// core 的 UI 线程调这个入口。所有 AppKit 操作切回主线程。
  fileprivate func handle(
    win: UInt8, op: UInt8, buf: UnsafeRawPointer?, bufLen: Int,
    logicalW: UInt32, logicalH: UInt32
  ) {
    // 帧数据只在本次调用期间有效，必须拷贝出来再异步贴。
    var copy: UnsafeMutableRawPointer?
    var count = 0
    if let buf, bufLen > 0, op == Op.blit {
      copy = UnsafeMutableRawPointer.allocate(byteCount: bufLen, alignment: 4)
      if let copy {
        copy.copyMemory(from: buf, byteCount: bufLen)
      }
      count = bufLen
    }
    var geo = (x: 0, y: 0, w: 0, h: 0)
    if let buf, op == Op.configure, bufLen >= 16 {
      let p = buf.assumingMemoryBound(to: Int32.self)
      geo = (Int(p[0]), Int(p[1]), Int(p[2]), Int(p[3]))
    }
    let lw = Int(logicalW), lh = Int(logicalH)
    let tEntry = CFAbsoluteTimeGetCurrent()
    if win == Win.vkbd.rawValue && op != Op.blit {
      Self.log("VKBD handle op=\(op) t=\(tEntry)")
    }

    DispatchQueue.main.async {
      defer { copy?.deallocate() }
      self.applyOnMain(win: Int(win), op: Int(op), geo: geo, frame: copy,
                       pixelW: lw, pixelH: lh, bufLen: count)
    }
  }

  /// 主线程执行真正的 AppKit 调用。
  private func applyOnMain(
    win: Int, op: Int, geo: (x: Int, y: Int, w: Int, h: Int),
    frame: UnsafeMutableRawPointer?, pixelW: Int, pixelH: Int, bufLen: Int
  ) {
    switch op {
    case Op.configure:
      sizes[win] = NSSize(width: geo.w, height: geo.h)
      let panel = ensurePanel(win)
      // 单位：core 传来的 geo.x/y/w/h **四个值全在设备像素域**
      // （x/y 来自 AppKit 的光标矩形与 NSScreen.frame，本机实测同域；
      //   w/h 是 core 按 scale 放大的渲染缓冲尺寸）。
      // AppKit 的 frame 用点，所以四个值统一除 scale。
      // 全链路统一用【点】：geo.x/y/w/h 直接就是 AppKit 的点制坐标，
      // 不再除 screenScale（除了 width/height 来自设备像素的渲染缓冲）。
      let sc = screenScale
      let screenPt = CGFloat(screenHeight)
      // ===== 单位域（实测钉死，勿再改）=====
      // core 发来的 geo.y 已经是 **flip 坐标**（左上原点）：外壳把光标矩形按
      // screenMaxY - rect.minY 换算后交给 core，core 沿用该值。
      // 实测锚点 rect.minY=134、screenH=1200 → geo.y=1045，与 1200-134 吻合。
      // 所以这里**不能再对 geo.y 翻一次**，只需把 flip 顶边换成 AppKit 底边：
      //   AppKit 底边 = 屏高 - flip 顶边 - 点制窗口高
      // geo.h 是**设备像素**（core 按 scale 放大的渲染缓冲），必须除 sc 才能
      // 参与点域减法 —— 漏除会让窗口整体下移一个窗口高（实测 119px vs 59.5pt）。
      let flippedY = screenPt - CGFloat(geo.y) - CGFloat(geo.h) / sc
      panel.setFrame(
        NSRect(x: CGFloat(geo.x),
               y: flippedY,
               width: CGFloat(geo.w) / sc,
               height: CGFloat(geo.h) / sc),
        display: false)
      // contentView 建时是 .zero，必须跟着窗口拉一次，否则 frame 变了视图还是0×0。
      // 改完必须**重新取 layer 存回layers[win]**：contentView 从 .zero 变成实际尺寸时
      // AppKit 可能重建 backing layer，此时 layers[win] 指向的是已脱离视图树的孤儿
      // layer —— blit 贴上去永远不显示。症状是「同一个字母第一次打没预览窗，
      // 第二次才出来」（第一次 blit 贴到孤儿 layer，第二次重建后才生效）。
      if let cv = panel.contentView {
        cv.frame = panel.contentLayoutRect
        cv.wantsLayer = true
        cv.layer?.contentsGravity = .resize
        layers[win] = cv.layer
      }
      // 候选窗通常早于设置窗出现（用户还没打开过设置），这里补装监听，
      // 否则点选功能在「只输入没开过设置」时是死的。
      installMouseTracking()

    case Op.show:
      let tShow = CFAbsoluteTimeGetCurrent()
      let panel = ensurePanel(win)
      noteFront(win)
      installMouseTracking()
      // 上屏前把 layers[win] 强制对齐到窗口当前的 backing layer。
      // 不信任任何缓存：AppKit 在contentView 尺寸变化/重建视图时会换 layer，
      // 而 layers[win] 是建窗时缓存的旧引用 → blit 贴到孤儿 layer，
      // 窗口在但内容永远空白。这里每次 show 都重新取一次，成本可忽略。
      if let cv = panel.contentView {
        cv.wantsLayer = true
        if let live = cv.layer {
          live.contentsGravity = .resize
          if layers[win] !== live {
            layers[win] = live
          }
        }
      }
      // **绝不能重建窗口** —— 重建会把 configure 设好的几何扔掉（frame 退回 200×200）。
      panel.level = .init(Int(CGShieldingWindowLevel()))
      if win == Win.settings.rawValue {
        // 设置窗要参与焦点管理，属性每次同步；候选窗不设（照 SquirrelPanel）
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        // 输入法是 .accessory 进程，不激活的话它的窗口不显示
        // （日志证据：visible=true / appActive=false / policy=1 却是看不见）。
        // .accessory 不能用 activate(ignoringOtherApps: true)，那会抢用户焦点，
        // 用 activate() 正常激活 —— 设置窗本来也要交互。
        if #available(macOS 14.0, *) {
          NSApp.activate()
        } else {
          NSApp.activate(ignoringOtherApps: true)
        }
        panel.makeKeyAndOrderFront(nil)
        // 首次显示时才挂监听（panel 存在之后 monitor 才有意义）
        installMouseTracking()
      } else {
        // 关键：不能用 orderFront —— 它要求进程处于活跃状态，而输入法是
        // .accessory 进程（appActive=false），实测窗口压根不进 WindowServer
        // 的屏幕列表（日志 sys=NOT_IN_LIST，AppKit 却报 visible=true）。
        // orderFrontRegardless 跳过这个要求，不抢焦点也能强制上屏
        //（微信/系统输入法同款）。
        // 不用 orderFront：它要求进程活跃，而输入法是 .accessory 进程
        // （appActive=false）。也**不能** activate：那会抢走用户正在输入的
        // 应用的焦点，导致打字中断。orderFrontRegardless 两者都不需要。
        panel.orderFrontRegardless()
        // 曾按 querySystemWindow()=="sys=NOT_IN_LIST" 做 setFrame 抖动兜底，
        // 已删 —— 实测该诊断 975/975 全是 NOT_IN_LIST（CGWindowListCopyWindowInfo
        // 从输入法进程查不到自身窗口），与实际可见性无关，等于每帧空跑抖动。
        // 判可见性要用 AppKit 的 isOnActiveSpace。
        if !panel.isOnActiveSpace {
          panel.collectionBehavior.insert(.moveToActiveSpace)
          panel.orderFrontRegardless()
        }
        // ==== 兜底：.accessory 进程的面板会被系统悄悄收起 ====
        // 输入法是 .accessory 进程（appActive=false / policy=1），
        // 这种进程的 NSPanel 在宿主变化、Space 切换、或其他面板抢层级后
        // 会被 WindowServer 直接摘掉，而 orderFrontRegardless 有时一次唤不醒。
        // 症状：core 认为窗口该显示（已发 op=1），AppKit 侧 isVisible 却仍是
        // false，用户看到「预览窗毫无规律地消失，再打字也不回来」。
        // 这里用 AppKit 自己的 isVisible（可靠）复查一遍，不可见就再叫醒。
        if !panel.isVisible {
          panel.orderFrontRegardless()
          panel.displayIfNeeded()
        }
        if !panel.isVisible {
          panel.orderFront(nil)
          panel.orderFrontRegardless()
          panel.display()
        }
      }

      if win == Win.vkbd.rawValue {
        Self.log("VKBD show-cost \(Int((CFAbsoluteTimeGetCurrent() - tShow) * 1000))ms visible=\(panel.isVisible) onSpace=\(panel.isOnActiveSpace)")
      }

    case Op.hide:
      if win == Win.vkbd.rawValue {
        Self.log("VKBD hide t=\(CFAbsoluteTimeGetCurrent())")
      }
      panels[win]?.orderOut(nil)

    case Op.blit:
      guard let frame, pixelW > 0, pixelH > 0 else { return }
      // blit 是最后一道路径，这里再兜一次layer 同步：configure/show 都可能被
      // AppKit 的重建layer 绕过，只有真正贴帧这一刻拿到的引用才算数。
      if let panel = panels[win], let live = panel.contentView?.layer, layers[win] !== live {
        layers[win] = live
      }
      drawFrame(win: win, ptr: frame, pixelW: pixelW, pixelH: pixelH, bufLen: bufLen)

    case Op.beginDrag:
      beginDrag(win)

    default:
      break
    }
  }

  /// 把主屏尺寸与缩放报给 core。
  /// 单位：**点**（NSScreen.frame 原值）。core 侧的 geo 同样是点制，全链路一致。
  private func reportScreenInfo() {
    guard let screen = NSScreen.screens.first else { return }
    let f = screen.frame
    let scale = screen.backingScaleFactor
    heng_set_screen_info(
      UInt32(max(0, Int32(f.width))), UInt32(max(0, Int32(f.height))),
      Float(scale))
    reportWorkArea(screen: screen, scale: scale)
  }

  /// 上报工作区（候选面板向下放不下时据此向上翻转）。
  ///
  /// 取 `visibleFrame` —— 它已排除 Dock 与菜单栏，与 Windows 的 rcWork同语义。
  /// 用 `frame`（整屏）会让光标贴底时误判「下方还有空间」，面板实际被 Dock 盖住。
  ///
  /// 坐标系换算（与 configure/blit 同一套）：
  ///   - AppKit 左下原点 → core 左上原点：`coreTop = screenH - vf.maxY`
  ///   - visibleFrame 是**点**，core 几何是**设备像素** → 乘 scale
  /// 翻转后的定位（paint 里flip 分支的 last_caret_top/flip_top）也用这个
  /// 上边界，口径必须一致，否则向上展开时会顶出屏幕。
  private func reportWorkArea(screen: NSScreen, scale: CGFloat) {
    let vf = screen.visibleFrame
    let screenH = screen.frame.height
    // 左下原点 → 左上原点
    let top = (screenH - vf.maxY) * scale
    let bottom = (screenH - vf.minY) * scale
    heng_set_work_area(Int32(top.rounded()), Int32(bottom.rounded()))
    Self.log("WA top=" + String(describing: Int32(top.rounded())) + " bottom=" + String(describing: Int32(bottom.rounded())) + " scale=" + String(describing: scale))
  }

  // MARK: - 窗口

  private func ensurePanel(_ win: Int) -> NSPanel {
    if let p = panels[win] { return p }

    let kind = Win(rawValue: win) ?? .candidate
    // 样式照抄能正常弹出的 SquirrelPanel（SquirrelPanel.swift:40）：
    // 候选窗/字母区 = .nonactivatingPanel（仅此一个）；设置窗 = .borderless（可激活）。
    // 之前给候选窗加 .fullSizeContentView + isFloatingPanel=false，WindowServer 直接不收
    // （日志 sys=NOT_IN_LIST：AppKit 说 visible=true，系统窗口列表里根本没有）。
    let style: NSWindow.StyleMask = (kind == .settings)
      ? .borderless
      : .nonactivatingPanel

    let panel = (kind == .settings)
      ? NSPanel(
          contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
          styleMask: style,
          backing: .buffered,
          defer: false)
      : HengOverlayPanel(
          contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
          styleMask: style,
          backing: .buffered,
          defer: false)
    // 透明三件套：不设这些，圆角外就是系统灰底方块
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    // 必须用 CGShieldingWindowLevel，不能用 .popUpMenu(3)：后者低于输入法
    // 宿主窗口的层级，窗口建好了也会被压到后面看不见。
    // 参照能正常弹出的 SquirrelPanel（level = CGShieldingWindowLevel）。
    panel.level = .init(Int(CGShieldingWindowLevel()))
    panel.isReleasedWhenClosed = false

    // ===== 候选窗/工具窗要能点选，必须显式开这两项 =====
    // nonactivatingPanel 默认 ignoresMouseEvents = true，点它等于点穿到下层应用，
    // 候选格/符号格永远收不到点击。设置窗是 .borderless 不受影响。
    if kind == .candidate || kind == .tools || kind == .emoji || kind == .vkbd {
      panel.ignoresMouseEvents = false
      // 不激活也能收点击：候选窗是 nonactivatingPanel，点击它不应抢走
      // 宿主应用（TextEdit 等）的键盘焦点，否则用户点一下候选词就丢了编辑焦点。
      // 绝不能设 becomesKeyOnlyIfNeeded：它让面板退出正常窗口管理流程，
      // 首次 orderFrontRegardless 还能被 WindowServer 强行收一次（日志 visible=true），
      // 但 orderOut 之后再 orderFrontRegardless 就不再入系统窗口列表
      // （实测 sys=NOT_IN_LIST）→ 窗口从进程活着到死都再也上不来，
      // 就是「打某个字母时预览窗消失、再打也不回来」的根因。
      panel.hidesOnDeactivate = false
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }


    let view = HengTrackingView(frame: .zero)
    // 悬停：core 靠 PointerMoved 算「鼠标下是哪个格子」并回填含义提示，
    // 而 local monitor 收不到 mouseMoved（事件只发给窗口，不进监视器）。
    // tracking area 带 .activeAlways，输入法进程非活跃也能拿到进入/移动/离开。
    view.onMove = { [weak self] ev in
      guard let self, self.dragWin == nil else { return }
      self.forward(ev, win: win)
    }
    view.onExit = {
      // kind=4 = PTR_EXIT：core 据此清掉 hover 与含义提示
      heng_push_pointer_event(UInt8(win), 4, 0, 0, 0, 0)
    }
    view.wantsLayer = true
    view.layer?.contentsGravity = .resize
    panel.contentView = view

    panels[win] = panel
    layers[win] = view.layer
    return panel
  }

  // MARK: - 贴帧

  /// 把预乘 BGRA 帧画进窗口 layer。
  ///
  /// core 的 `Argb` 是 `#[repr(C)]` 且字段序 b,g,r,a —— 内存序就是预乘 BGRA，
  /// 与 `kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host` 一致，
  /// 所以整块 memcpy 即可，零逐像素转换。
  private func drawFrame(win: Int, ptr: UnsafeMutableRawPointer, pixelW: Int, pixelH: Int, bufLen: Int) {
    guard let layer = layers[win] else { return }
    let bytesPerRow = pixelW * 4
    let need = bytesPerRow * pixelH
    // 硬校验：CoreGraphics 会按 pixelW/pixelH 去读**need** 字节，
    // 缓冲不足就直接踩内存（崩溃报告实锤：
    // ERROR_CGDataProviderCreateWithData_BufferIsNotBigEnough → SIGBUS）。
    // 这里宁可直接丢掉这一帧，也不能让它越界。
    if bufLen < need {
      Self.log("BLIT DROP win=\(win) bufLen=\(bufLen) need=\(need) px=\(pixelW)x\(pixelH)")
      return
    }

    // ★ 必须拷贝一份，不能直接引用 ptr。
    // core 侧 `render_buf` 是**复用的单一缓冲**（ui.rs:3452 声明，
    // 只在尺寸变化时重建），每次 paint 都往同一块内存重绘，随后
    // 把 `buf.as_ptr()` 交给我们。若直接用它构造 CGDataProvider，
    // layer.contents 引用的就是那块会被下一帧覆写的内存 ——
    // 表现为「字母区看着对、候选区空白/错乱、内容随机跳动」，
    // 因为两区在同一帧的不同时刻被写。
    // 拷贝后 CGDataProvider 引用的是自己的内存，生命周期独立于 core。
    // 生命周期：layer.contents 一直持有这张 CGImage，直到下一帧被替换。
    // 所以缓冲必须活过本次调用 —— 放进静态缓存复用（尺寸相同则原地覆写，
    // 尺寸变了才重新分配），既不提前释放也不每帧 malloc。
    let owned: UnsafeMutableRawPointer
    if let cached = Self.frameBuffers[win], cached.allocated == need {
        owned = cached.ptr
    } else {
        Self.frameBuffers[win]?.ptr.deallocate()
        owned = UnsafeMutableRawPointer.allocate(byteCount: need, alignment: 16)
        Self.frameBuffers[win] = (ptr: owned, allocated: need)
    }
    owned.copyMemory(from: ptr.assumingMemoryBound(to: UInt8.self), byteCount: need)

    let space = CGColorSpaceCreateDeviceRGB()
    // 预乘 BGRA。Swift 的 CGBitmapInfo 没有 byteOrder32Host，只有 Little/Big；
    // 本机（x86_64 / arm64）是小端，byteOrder32Little 即等价于 Host。
    // 注意 byteOrder32Little 是 static 成员，不能写在实例后面链式调用。
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
      .union(CGBitmapInfo.byteOrder32Little)

    // CGContext.draw(_:in:) 在 Swift 里只接受 CGImage / CGLayer，
    // 不能直接喂像素数据（裸指针和 Data 都会被解析成 CGLayer 重载而报错）。
    // 所以走 CGDataProvider：包住我们自己的缓冲 → CGImage → 画进 layer。
    guard let provider = CGDataProvider(
      dataInfo: nil, data: owned, size: need,
      releaseData: { _, _, _ in })
    else {
      Self.log("BLIT FAIL provider")
      return
    }
    guard let img = CGImage(
      width: pixelW, height: pixelH, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: bytesPerRow, space: space, bitmapInfo: info,
      provider: provider, decode: nil, shouldInterpolate: false,
      intent: .defaultIntent)
    else {
      Self.log("BLIT FAIL cgimage px=\(pixelW)x\(pixelH) info=\(info.rawValue)")
      return
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.contents = img
    layer.contentsGravity = .resize
    CATransaction.commit()
    Self.blitCount += 1
    // 每窗首次贴帧时落一张 PPM（/tmp/heng-dump-w<N>.ppm），核对 core 画得对不对。
    // 只写一次，不影响性能。
    if !Self.dumpedWindows.contains(win) {
      Self.dumpedWindows.insert(win)
      Self.dumpFrame(win: win, img: img, w: pixelW, h: pixelH)
    }
  }

  private static var blitCount = 0
  private static var dumpedWindows: Set<Int> = []

  /// 每窗一份「自有」像素缓冲。core 的 `render_buf` 是复用内存，
  /// 直接给 CGDataProvider 用会被下一帧覆写 → 画面撕裂/空白。
  /// 这里按窗口各存一份拷贝，CGImage 的生命周期就与 core 解耦。
  private static var frameBuffers: [Int: (ptr: UnsafeMutableRawPointer, allocated: Int)] = [:]

  /// 把 CGImage 写成二进制 PPM。只取 alpha 合成后的 RGB（白底），
  /// 便于在无 GUI 环境里直接看 core 渲染成了什么样。
  private static func dumpFrame(win: Int, img: CGImage, w: Int, h: Int) {
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(
      data: &pixels, width: w, height: h, bitsPerComponent: 8,
      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var out = Data("P6\n\(w) \(h)\n255\n".utf8)
    out.reserveCapacity(out.count + w * h * 3)
    let bytes = [UInt8](pixels)
    for i in stride(from: 0, to: w * h, by: 1) {
      let a = Int(bytes[i * 4 + 3])
      // 白底合成：透明像素显示为白，方便看真实观感
      let r = (Int(bytes[i * 4]) * a + 255 * (255 - a)) / 255
      let g = (Int(bytes[i * 4 + 1]) * a + 255 * (255 - a)) / 255
      let b = (Int(bytes[i * 4 + 2]) * a + 255 * (255 - a)) / 255
      out.append(UInt8(min(255, r))); out.append(UInt8(min(255, g))); out.append(UInt8(min(255, b)))
    }
    let path = "/tmp/heng-dump-w\(win).ppm"
    try? out.write(to: URL(fileURLWithPath: path))
    Self.log("DUMP win=\(win) -> \(path) \(w)x\(h)")
  }

  /// 用 CGWindowList 反查我们这个 panel 在系统眼里的真实状态。
  /// AppKit 说 visible=true 但用户看不见时，只有系统列表能给出裁决。
  private static func querySystemWindow(_ panel: NSWindow) -> String {
    let wid = CGWindowID(panel.windowNumber)
    guard wid != 0 else { return "sys=noWindowNumber" }
    guard let list = CGWindowListCopyWindowInfo(
      [.optionIncludingWindow], kCGNullWindowID) as? [[String: Any]]
    else { return "sys=listUnavailable" }
    for w in list {
      guard let n = w[kCGWindowNumber as String] as? CGWindowID, n == wid else { continue }
      let onscreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
      let alpha = (w[kCGWindowAlpha as String] as? Double) ?? -1
      let layer = (w[kCGWindowLayer as String] as? Int) ?? -1
      let bounds = w[kCGWindowBounds as String] ?? "?"
      return "sys=onScreen(onscreen=\(onscreen) alpha=\(alpha) layer=\(layer) bounds=\(bounds))"
    }
    return "sys=NOT_IN_LIST"
  }

  private static func rectStr(_ r: NSRect) -> String {
    "(\(Int(r.origin.x)),\(Int(r.origin.y)) \(Int(r.width))x\(Int(r.height)))"
  }

  // MARK: - 拖动

  /// 窗口进入拖动：记录基准点，后续 .leftMouseDragged 里按位移改 frame。
  /// 设置窗与工具窗（表情/符号）共用：core 判定顶栏拖动带后发 OP_BEGIN_DRAG。
  ///
  /// NSWindow 没有 `performWindowMoveWithEvent` 这种公开 API（查过 SDK：
  /// 只有 `movableByWindowBackground`，那是给系统标题栏用的，自绘无边框窗口不适用），
  /// 所以按另两端的语义自己算：拖动期间持续收到事件 → 窗口位置 = 拖起时位置 + 位移。
  private func beginDrag(_ win: Int) {
    guard let panel = panels[win] else { return }
    dragWin = win
    Self.log("DRAG begin win=\(win) origin=\(panel.frame.origin)")
    // 拖动全程只比「窗口原点」和「指针屏幕位置」两个 AppKit 左下原点量，
    // core 的左上原点在这里不参与，避免两套坐标混算出方向错乱的位移。
    let screen = NSEvent.mouseLocation
    dragStart = (panel.frame.origin, screen)
  }

  // MARK: - 鼠标事件上报

  /// NSPanel 的 contentView 收不到鼠标（我们不装NSView 子类），
  /// 所以用 window 的事件监听：给 panel 挂一个本地事件 monitor。
  /// 这里由 `installMouseTracking()` 在设置窗首次显示时调用一次。
  func installMouseTracking() {
    guard !mouseMonitorInstalled else { return }
    // 只要有任何面板就装。原来要求「候选窗或设置窗已存在」，于是
    // 「刚启动就打开表情窗」时监视器根本不装 —— 点格子/滚轮/关闭/拖动全哑。
    guard !panels.isEmpty else { return }
    mouseMonitorInstalled = true

    let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel]
    // local monitor 只拦截本进程窗口上的事件。设置窗与候选窗共用一个 monitor，
    // 按事件落点分发到对应窗口 —— 两个 monitor 会被后装的截走，反而漏事件。
    monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      guard let self else { return event }
      // 拖动中事件只发给拖起那个窗口：窗口跟着指针走，落点命中测试随时可能
      // 命中另一个（哪怕已隐藏、frame 还留在原处的）面板，中途改道就会「拖两下就断」。
      if let dragWin = self.dragWin {
        self.forward(event, win: dragWin)
        if event.type == .leftMouseUp {
          self.dragWin = nil
          if let p = self.panels[dragWin] {
            Self.log("DRAG end win=\(dragWin) origin=\(p.frame.origin)")
          }
        }
        return event
      }
      // 按落点分发：候选窗 / 设置窗 / 工具窗各自收自己的事件。
      // 工具窗是 nonactivatingPanel，点击不抢宿主键盘焦点。
      if let win = self.windowUnderMouse(event) {
        if event.type == .leftMouseDown {
          self.noteFront(win)
          self.panels[win]?.orderFrontRegardless()
        }
        self.forward(event, win: win)
      }
      return event
    }
  }

  /// 把窗口记到最前（只维护顺序，不动窗口层级）。
  private func noteFront(_ win: Int) {
    zOrder.removeAll { $0 == win }
    zOrder.insert(win, at: 0)
  }

  /// 事件落在哪个窗口上。
  /// 首选 event.window —— 这是 AppKit 已经判好的真实落点，比重叠窗口的
  /// 坐标命中测试可靠；拿不到才退回按 zOrder 的 frame 命中测试。
  private func windowUnderMouse(_ event: NSEvent) -> Int? {
    if let w = event.window, let hit = panels.first(where: { $0.value === w })?.key {
      return hit
    }
    let loc = NSEvent.mouseLocation
    let all = [
      Win.candidate.rawValue, Win.settings.rawValue,
      Win.tools.rawValue, Win.emoji.rawValue, Win.vkbd.rawValue
    ]
    var order = zOrder
    order.append(contentsOf: all.filter { !zOrder.contains($0) })
    for win in order {
      // 必须判 isVisible：隐藏的面板 frame 还停在原处，会把本属于工具窗的
      // 点击/拖动抢过去（表现为工具窗拖两下就静止，实际在拖一个看不见的窗）。
      if let panel = panels[win], panel.isVisible, panel.frame.contains(loc) { return win }
    }
    return nil
  }

  private var monitor: Any?
  private var mouseMonitorInstalled = false
  /// 窗口前后顺序：最近显示/点击的排最前。命中测试必须按它来，
  /// 用固定顺序会让「两个窗重叠时点到的永远是底下那个」，表现成整窗口点不动。
  private var zOrder: [Int] = []
  /// 正在拖动的窗口号（mouseDown→mouseUp 期间锁定事件路由）
  private var dragWin: Int?

  private func forward(_ event: NSEvent, win: Int) {
    // 坐标必须按**事件自己的窗口**换算：路由到的下标和事件所属窗口不一致时
    // （拖动、置前切换的瞬间都可能），用别的窗口换算会得到完全错的格子。
    guard let panel = event.window ?? panels[win], let view = panel.contentView else { return }
    let loc = view.convert(event.locationInWindow, from: nil)
    // core 约定的是**设备像素** + **左上原点**（blit 的 px 尺寸就是这个量级）。
    // loc 是 contentView 的点坐标且左下原点，所以：乘 scale 转设备像素、翻 y 转原点。
    let scale = view.window?.backingScaleFactor ?? 1
    let x = Float(loc.x * scale)
    let y = Float((view.bounds.height - loc.y) * scale)

    switch event.type {
    case .mouseMoved:
      // tracking area 的移动事件：core 靠它算「光标下是哪个格子」
      // （悬停高亮 + 含义提示），漏了这个分支就只剩「离开窗口」一条路。
      heng_push_pointer_event(UInt8(win), 0, x, y, 0, 0)
    case .leftMouseDown:
      heng_push_pointer_event(UInt8(win), 1, x, y, 0, 0)
      // 不在这里起拖：是否在拖动带由 core 判定（另两端的拖动带语义都在 core），
      // 它确认后回 OP_BEGIN_DRAG，那时才记基准点。否则点任何按钮都会拖窗口。
    case .leftMouseDragged:
      // 拖动中：按位移直接改窗口位置，不再上报给 core（core 那条路径
      // 是给 Windows 的 HTCAPTION 用的，AppKit 没有等价机制）
      if let panel = panels[win], let start = dragStart {
        let now = NSEvent.mouseLocation
        panel.setFrameOrigin(
          NSPoint(x: start.origin.x + (now.x - start.pointer.x),
                  y: start.origin.y + (now.y - start.pointer.y)))
        heng_push_pointer_event(UInt8(win), 0, x, y, 0, 0)
      } else {
        heng_push_pointer_event(UInt8(win), 0, x, y, 0, 0)
      }
    case .leftMouseUp:
      dragStart = nil
      heng_push_pointer_event(UInt8(win), 2, x, y, 0, 0)
      // 点选候选的上屏**不再**在这里取：点击从主线程发给 core UI 线程后，
      // core 要跨两轮循环才产出 commit，比主队列下一轮晚约 9ms，
      // 在这里取必定是空的（实测 takeUiCommit返回 nil）。
      // 改由 core 在文本就绪时经 heng_set_commit_handler 回调，
      // 见 observeCandidateClick() 与 hengRegisterCommitHandler()。
    case .scrollWheel:
      // core（对齐 Windows 的 WHEEL_DELTA）约定「一档 = 50 逻辑 px」。
      // macOS 鼠标滚轮一档只有 ±1~3 行，直接透传会被 core 当成 1px，
      // 慢慢滚永远凑不满一行（48px）→ 看起来完全不响应。
      var dx = Float(event.scrollingDeltaX)
      var dy = Float(event.scrollingDeltaY)
      if !event.hasPreciseScrollingDeltas {
        dx *= 50
        dy *= 50
      }
      heng_push_pointer_event(UInt8(win), 3, x, y, dx, dy)
    default:
      break
    }
  }
}
/// 承载帧的视图。加 tracking area 只为拿到 mouseMoved / mouseExited：
/// 输入法的面板不激活，也没有 mouseMoved 的本地监视器通路。
final class HengTrackingView: NSView {
  var onMove: ((NSEvent) -> Void)?
  var onExit: (() -> Void)?
  private var tracking: NSTrackingArea?

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    tracking = area
  }

  // 首次点击直接当内容点击，不拿去激活窗口
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseMoved(with event: NSEvent) { onMove?(event) }
  override func mouseEntered(with event: NSEvent) { onMove?(event) }
  override func mouseExited(with event: NSEvent) { onExit?() }
}

/// 候选窗/字母区专用面板：拒绝成为 key / main 窗口。
///
/// CGShieldingWindowLevel 的窗口一旦拿到 key 状态，宿主应用的
/// NSTextInputContext 就再也收不到键盘事件（Qt / QtWebEngine 尤其明显），
/// 表现为「打出第一个字、候选窗出现之后整个键盘失效」，连 ⌘Z 都没反应
/// —— 键全被这个看不见焦点的面板吃掉了。
/// 点击选词不依赖 key 状态（nonactivatingPanel 本来就能不激活收点击），
/// 所以这里直接封死。
final class HengOverlayPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}




// MARK: - 区域截图（自绘覆盖窗 + 两级工具条 + 注释）

enum ShotTool: Int {
  case pen = 0, arrow, rect, ellipse, line, mosaicBrush, mosaicRect

  var isMosaic: Bool { self == .mosaicBrush || self == .mosaicRect }
}

/// 一条注释：几何 + 样式
struct Annotation {
  var tool: ShotTool
  var points: [NSPoint]      // pen: 点列；其余: [起点, 终点]
  var color: NSColor
  var width: CGFloat
  var filled: Bool
  var outline: Bool
  /// 马赛克/模糊：块大小（点）
  var block: CGFloat = 12
  /// true = 高斯模糊，false = 像素化
  var blur: Bool = false
}

/// 马赛克注释的裁剪路径（涂抹=轨迹描边，框选=矩形）
func mosaicClipPath(_ a: Annotation) -> CGPath? {
  let p = CGMutablePath()
  if a.tool == .mosaicBrush {
    guard let first = a.points.first else { return nil }
    p.move(to: first)
    for q in a.points.dropFirst() { p.addLine(to: q) }
  } else {
    guard a.points.count >= 2 else { return nil }
    p.addRect(CGRect(
      x: min(a.points[0].x, a.points[1].x), y: min(a.points[0].y, a.points[1].y),
      width: abs(a.points[1].x - a.points[0].x), height: abs(a.points[1].y - a.points[0].y)))
  }
  return p
}

func mosaicBounds(_ a: Annotation) -> NSRect {
  if a.tool == .mosaicBrush {
    let xs = a.points.map { $0.x }, ys = a.points.map { $0.y }
    guard let minX = xs.min(), let maxX = xs.max(),
          let minY = ys.min(), let maxY = ys.max() else { return .zero }
    return NSRect(x: minX - a.width / 2, y: minY - a.width / 2,
                  width: maxX - minX + a.width, height: maxY - minY + a.width)
  }
  guard a.points.count >= 2 else { return .zero }
  return NSRect(
    x: min(a.points[0].x, a.points[1].x), y: min(a.points[0].y, a.points[1].y),
    width: abs(a.points[1].x - a.points[0].x), height: abs(a.points[1].y - a.points[0].y))
}

func drawAnnotation(_ a: Annotation) {
  guard a.points.count >= 2 else { return }
  a.color.setStroke()
  let path = NSBezierPath()
  path.lineWidth = a.width
  path.lineCapStyle = .round
  path.lineJoinStyle = .round
  switch a.tool {
  case .pen:
    path.move(to: a.points[0])
    for p in a.points.dropFirst() { path.line(to: p) }
    path.stroke()
  case .rect, .ellipse:
    let r = NSRect(
      x: min(a.points[0].x, a.points[1].x), y: min(a.points[0].y, a.points[1].y),
      width: abs(a.points[1].x - a.points[0].x), height: abs(a.points[1].y - a.points[0].y))
    guard r.width > 1, r.height > 1 else { return }
    let p = a.tool == .rect ? NSBezierPath(rect: r) : NSBezierPath(ovalIn: r)
    p.lineWidth = a.width
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    if a.filled {
      a.color.setFill()
      p.fill()
    }
    if a.outline {
      a.color.setStroke()
      p.stroke()
    }
  case .line:
    path.move(to: a.points[0])
    path.line(to: a.points[1])
    path.stroke()
  case .mosaicBrush, .mosaicRect:
    return  // 由马赛克滤镜单独处理
  case .arrow:
    let s = a.points[0], e = a.points[1]
    let angle = atan2(e.y - s.y, e.x - s.x)
    let dirX = cos(angle), dirY = sin(angle)
    let len: CGFloat = max(10, a.width * 4)
    let spread: CGFloat = .pi / 7
    // 杆收到三角内部就停，否则圆头会从尖上穿出去
    let shaftEnd = NSPoint(
      x: e.x - dirX * len * 0.55, y: e.y - dirY * len * 0.55)
    path.move(to: s)
    path.line(to: shaftEnd)
    path.stroke()
    // 三角整体前移半个线宽，把杆端盖住
    let tip = NSPoint(x: e.x + dirX * a.width * 0.5, y: e.y + dirY * a.width * 0.5)
    let head = NSBezierPath()
    head.move(to: tip)
    head.line(to: NSPoint(x: tip.x - len * cos(angle - spread), y: tip.y - len * sin(angle - spread)))
    head.line(to: NSPoint(x: tip.x - len * cos(angle + spread), y: tip.y - len * sin(angle + spread)))
    head.close()
    a.color.setFill()
    head.fill()
  }
}

/// 覆盖窗专用：无边框窗口默认不能成为 key
final class OverlayWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

final class ScreenshotOverlay: NSObject {
  static let shared = ScreenshotOverlay()
  private var windows: [NSWindow] = []
  private var active = false
  private var watchdog: Timer?
  var isActive: Bool { active }

  private static let openClock = Date()
  static func openMark(_ tag: String) {
    #if DEBUG
    let t = Date().timeIntervalSince(openClock) * 1000
    let line = String(format: "%7.1fms  %@\n", t, tag)
    let p = "/tmp/heng-open.log"
    if let h = FileHandle(forWritingAtPath: p) {
      h.seekToEndOfFile()
      h.write(line.data(using: .utf8)!)
      try? h.close()
    } else {
      try? line.write(toFile: p, atomically: true, encoding: .utf8)
    }
    #endif
  }

  func begin() {
    // 上一轮如果没收干净，先关掉，避免两套覆盖窗同时存在
    if active || !windows.isEmpty {
      Self.openMark("stale session -> close")
      close()
    }
    active = true
    Self.openMark("begin")
    let screens = NSScreen.screens
    var bases = [NSImage?](repeating: nil, count: screens.count)
    let useSCK: Bool
    if #available(macOS 14.0, *) {
      useSCK = true
    } else {
      useSCK = false
      // 老系统没有排除自身窗口的能力，只能先截再建窗
      if screens.count > 1 {
        DispatchQueue.concurrentPerform(iterations: screens.count) { i in
          bases[i] = Self.captureScreen(screens[i])
        }
      } else if let only = screens.first {
        bases[0] = Self.captureScreen(only)
      }
    }
    Self.openMark("capture-path decided")
    var captured: [(NSScreen, SelectionView)] = []
    for (idx, screen) in screens.enumerated() {
      let base = bases[idx]
      let win = OverlayWindow(
        contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      win.level = .init(Int(CGShieldingWindowLevel()))
      win.backgroundColor = .clear
      win.isOpaque = false
      win.hasShadow = false
      win.ignoresMouseEvents = false
      win.acceptsMouseMovedEvents = true
      win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
      win.isReleasedWhenClosed = false
      let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
      view.wantsLayer = true
      view.layer?.backgroundColor = .clear
      view.onCancel = { [weak self] in self?.cancel() }
      view.onConfirm = { [weak self] rect, owner in self?.confirm(rect, from: owner) }
      view.onSave = { [weak self] rect, owner in self?.saveToFolder(rect, from: owner) }
      view.setBaseImage(base)
      captured.append((screen, view))
      win.contentView = view
      win.makeKeyAndOrderFront(nil)
      windows.append(win)
      Self.openMark("window \(idx) shown")
    }
    Self.openMark("before activate")
    NSApp.activate(ignoringOtherApps: true)
    windows.first?.makeKey()
    windows.first?.makeFirstResponder(windows.first?.contentView)
    Self.openMark("after activate")
    watchdog = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { [weak self] _ in
      self?.cancel()
    }
    if useSCK {
      // 先把界面亮出来（此时看到的是实时画面），再异步补底图，排除自己所有窗口
      for (screen, view) in captured {
        // 不在主线程上等：主线程被输入法自己的活儿占住时，后台照样能截
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.16) {
          guard #available(macOS 14.0, *) else { return }
          Task {
            if let img = await Self.captureExcludingSelf(screen) {
              await MainActor.run {
                view.setBaseImage(img)
                Self.openMark("base image ready")
              }
            }
          }
        }
      }
    }
  }

  /// 用 ScreenCaptureKit 截屏，排除本 App 的所有窗口（菜单、覆盖窗都不会进画面）
  @available(macOS 14.0, *)
  private static func captureExcludingSelf(_ screen: NSScreen) async -> NSImage? {
    guard let num = screen.deviceDescription[
      NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
    let displayID = CGDirectDisplayID(num.uint32Value)
    do {
      Self.openMark("sck: content begin")
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
      Self.openMark("sck: content ok")
      guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
        return nil
      }
      // 找不到自己就没法排除覆盖窗，宁可不要这张图
      guard let me = content.applications.first(where: { $0.processID == getpid() }) else {
        return nil
      }
      let filter = SCContentFilter(
        display: display,
        excludingApplications: [me],
        exceptingWindows: [])
      let cfg = SCStreamConfiguration()
      let scale = screen.backingScaleFactor
      cfg.width = Int(screen.frame.width * scale)
      cfg.height = Int(screen.frame.height * scale)
      cfg.showsCursor = false
      cfg.captureResolution = .best
      Self.openMark("sck: capture begin")
      let cg = try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: cfg)
      Self.openMark("sck: capture ok")
      return NSImage(cgImage: cg, size: screen.frame.size)
    } catch {
      return nil
    }
  }

  /// 整屏截图（在覆盖窗出现之前调用，不需要隐藏任何东西）
  private static func captureScreen(_ screen: NSScreen) -> NSImage? {
    let frame = screen.frame
    let mainH = CGDisplayBounds(CGMainDisplayID()).height
    let x = Int(frame.origin.x.rounded())
    let y = Int((mainH - frame.origin.y - frame.height).rounded())
    let w = max(1, Int(frame.width.rounded()))
    let h = max(1, Int(frame.height.rounded()))
    let tmp = NSTemporaryDirectory() + "heng-base-\(x).png"
    try? FileManager.default.removeItem(atPath: tmp)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-R", "\(x),\(y),\(w),\(h)", tmp]
    do { try task.run() } catch { return nil }
    task.waitUntilExit()
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: tmp)) else { return nil }
    return NSImage(data: data)
  }

  private func hideAll() { for w in windows { w.orderOut(nil) } }
  private func showAll() {
    for w in windows { w.makeKeyAndOrderFront(nil) }
    NSApp.activate(ignoringOtherApps: true)
    windows.first?.makeKey()
    windows.first?.makeFirstResponder(windows.first?.contentView)
  }
  private func close() {
    Self.openMark("close (\(windows.count) windows)")
    watchdog?.invalidate()
    watchdog = nil
    for w in windows { w.orderOut(nil); w.contentView = nil }
    windows.removeAll()
    active = false
  }
  func cancel() { guard active else { return }; close() }

  private func grab(
    _ rect: NSRect, screen: NSScreen, windowID: CGWindowID = 0,
    _ done: @escaping (Data?) -> Void
  ) {
    let frame = screen.frame
    let globalBL = NSPoint(x: frame.origin.x + rect.origin.x, y: frame.origin.y + rect.origin.y)
    let mainH = CGDisplayBounds(CGMainDisplayID()).height
    let x = Int(globalBL.x.rounded())
    let y = Int((mainH - globalBL.y - rect.height).rounded())
    let w = max(1, Int(rect.width.rounded()))
    let h = max(1, Int(rect.height.rounded()))
    // 窗口级截图（-l）只截目标窗口，覆盖窗不会进画面，不需要隐藏
    if windowID == 0 { hideAll() }
    let delay: Double = windowID == 0 ? 0.12 : 0
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      let tmp = NSTemporaryDirectory() + "heng-shot.png"
      try? FileManager.default.removeItem(atPath: tmp)
      let task = Process()
      task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      if windowID != 0 {
        task.arguments = ["-x", "-o", "-l\(windowID)", tmp]
      } else {
        task.arguments = ["-x", "-R", "\(x),\(y),\(w),\(h)", tmp]
      }
      do { try task.run() } catch { done(nil); return }
      task.waitUntilExit()
      if let data = try? Data(contentsOf: URL(fileURLWithPath: tmp)) { done(data); return }
      guard windowID != 0 else { done(nil); return }
      let fb = Process()
      fb.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      fb.arguments = ["-x", "-R", "\(x),\(y),\(w),\(h)", tmp]
      do { try fb.run() } catch { done(nil); return }
      fb.waitUntilExit()
      done(try? Data(contentsOf: URL(fileURLWithPath: tmp)))
    }
  }

  private func composite(
    _ data: Data, annotations: [Annotation], sel: NSRect, scale: CGFloat
  ) -> Data? {
    guard !annotations.isEmpty else { return data }
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: max(1, Int(sel.width * scale)), pixelsHigh: max(1, Int(sel.height * scale)),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return data }
    // 必须在建 context 之前设 size
    rep.size = sel.size
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return data }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    NSImage(data: data)?.draw(in: NSRect(origin: .zero, size: sel.size))
    ctx.cgContext.translateBy(x: -sel.minX, y: -sel.minY)
    for a in annotations {
      if a.tool.isMosaic {
        drawMosaicInComposite(a, base: data, sel: sel, scale: scale, ctx: ctx)
      }
      else { drawAnnotation(a) }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
  }

  private static let compositeCI = CIContext()

  private func drawMosaicInComposite(
    _ a: Annotation, base: Data, sel: NSRect, scale: CGFloat, ctx: NSGraphicsContext
  ) {
    guard let path = mosaicClipPath(a), let ci = CIImage(data: base) else { return }
    let box = mosaicBounds(a)
    guard box.width > 0.5, box.height > 0.5 else { return }
    let cg = ctx.cgContext
    cg.saveGState()
    if a.tool == .mosaicBrush {
      cg.addPath(path)
      cg.setLineWidth(a.width)
      cg.setLineCap(.round)
      cg.setLineJoin(.round)
      cg.replacePathWithStrokedPath()
      cg.clip()
    } else {
      cg.addPath(path)
      cg.clip()
    }
    // 选区本地坐标（点）→ 图片像素
    let px = CGRect(
      x: (box.minX - sel.minX) * scale, y: (box.minY - sel.minY) * scale,
      width: box.width * scale, height: box.height * scale)
    let extent = ci.extent
    let region = px.intersection(extent)
    if region.width > 1, region.height > 1 {
      var out: CIImage
      if a.blur {
        out = ci.clampedToExtent()
          .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: a.block * scale])
          .cropped(to: region)
      } else {
        out = ci
          .applyingFilter("CIPixellate", parameters: [
            kCIInputScaleKey: a.block * scale,
            kCIInputCenterKey: CIVector(x: region.midX, y: region.midY),
          ])
          .cropped(to: region)
      }
      if let img = Self.compositeCI.createCGImage(out, from: region) {
        // region 可能被图片边界裁剪过，目标矩形必须按 region 反算，否则会拉伸
        let dst = NSRect(
          x: sel.minX + region.minX / scale, y: sel.minY + region.minY / scale,
          width: region.width / scale, height: region.height / scale)
        NSImage(cgImage: img, size: dst.size).draw(in: dst)
      }
    }
    cg.restoreGState()
  }

  private static func stamp() -> String {
    let df = DateFormatter()
    df.dateFormat = "yyyyMMddHHmmssSSS"
    return df.string(from: Date())
  }

  /// 内存里已有底图就直接裁，只有"单击截某个窗口"才需要窗口级重截
  private func baseImage(
    _ rect: NSRect, from view: SelectionView, screen: NSScreen, scale: CGFloat
  ) -> Data? {
    if view.windowIDForCapture == 0, let data = view.frozenCrop(rect) { return data }
    return nil
  }

  private func confirm(_ rect: NSRect, from view: SelectionView) {
    guard active, let screen = view.window?.screen else { cancel(); return }
    let ann = view.annotations
    let scale = screen.backingScaleFactor
    let finish: (Data?) -> Void = { [weak self] data in
      guard let self else { return }
      defer { self.cancel() }
      guard let data else { NSSound.beep(); return }
      let final = self.composite(data, annotations: ann, sel: rect, scale: scale) ?? data
      guard let img = NSImage(data: final) else { NSSound.beep(); return }
      let pb = NSPasteboard.general
      pb.clearContents()
      pb.writeObjects([img])
      let dst = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop/衡截图-\(Self.stamp()).png")
      try? final.write(to: dst)
    }
    if let data = baseImage(rect, from: view, screen: screen, scale: scale) {
      finish(data)
    } else {
      grab(rect, screen: screen, windowID: view.windowIDForCapture, finish)
    }
  }

  private func saveToFolder(_ rect: NSRect, from view: SelectionView) {
    guard active, let screen = view.window?.screen else { cancel(); return }
    let ann = view.annotations
    let scale = screen.backingScaleFactor
    let handle: (Data?) -> Void = { [weak self] data in
      guard let self else { return }
      guard let data else { NSSound.beep(); self.showAll(); return }
      let final = self.composite(data, annotations: ann, sel: rect, scale: scale) ?? data
      // 覆盖窗在 shielding 级别，不收起的话 NSOpenPanel 会被压在下面看不见
      self.hideAll()
      let panel = NSOpenPanel()
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.allowsMultipleSelection = false
      panel.canCreateDirectories = true
      panel.prompt = "保存到此处"
      panel.message = "选择保存截图的文件夹"
      let ok = panel.runModal() == .OK
      let dir = panel.url
      guard ok, let dir else { self.showAll(); return }
      self.close()
      let dst = dir.appendingPathComponent("\(Self.stamp()).png")
      do { try final.write(to: dst) } catch { NSSound.beep() }
    }
    if let data = baseImage(rect, from: view, screen: screen, scale: scale) {
      handle(data)
    } else {
      grab(rect, screen: screen, windowID: view.windowIDForCapture, handle)
    }
  }
}

/// 选区视图：遮罩 + 选区 + 把手 + 一级/二级工具条 + 颜色弹层 + 注释
final class SelectionView: NSView {
  var onCancel: (() -> Void)?
  var onConfirm: ((NSRect, SelectionView) -> Void)?
  var onSave: ((NSRect, SelectionView) -> Void)?

  private(set) var annotations: [Annotation] = []
  private var redoStack: [Annotation] = []
  private var draft: Annotation?

  // 工具状态
  private enum Primary: Int { case shape, arrow, pen, text, mosaic }
  private var primary: Primary? = nil
  private var shapeKind: ShotTool = .rect
  private var tool: ShotTool? = nil
  private var color: NSColor = NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1)
  private var lineWidth: CGFloat = 4
  /// 形状属性二选一：false = 外框（描边），true = 填充（此时粗细禁用）
  private var shapeFilled = false
  private var showPalette = false
  private var showCustom = false
  private enum CustomDrag { case none, sv, hue }
  private var customDrag: CustomDrag = .none
  private var hueValue: CGFloat = 0
  private var satValue: CGFloat = 1
  private var brightValue: CGFloat = 1

  private var sel: NSRect = .zero
  private var dragging = false
  private var dragStart: NSPoint = .zero
  private var resizeHandle: Int = -1
  private var moveStart: NSPoint = .zero
  private var moveOrigin: NSRect = .zero
  private var selBefore: NSRect = .zero
  private var track: NSTrackingArea?
  private var hoverRect: NSRect = .zero
  private var hoverID: CGWindowID = 0
  private var selWindowID: CGWindowID = 0
  var windowIDForCapture: CGWindowID { selWindowID }
  private var pressAt: NSPoint = .zero
  private var moved = false
  private var tipText: String?
  private var tipAnchor: NSRect = .zero

  // 马赛克
  private var mosaicBlur = false
  private var mosaicBrushMode = true
  private var mosaicBlock: CGFloat = 5
  private var brushSize: CGFloat = 20
  private var showBrushMenu = false
  private var mosaicFrameCache: (key: String, image: NSImage)?

  /// 画过东西之后就锁住选区，不能拖动/改大小（撤销到空自动解锁）
  private var selLocked: Bool { !annotations.isEmpty }
  private var ciContext = CIContext()
  private var sliderDrag = false

  private let presets: [NSColor] = [
    NSColor(red: 1.00, green: 0.27, blue: 0.23, alpha: 1),
    NSColor(red: 1.00, green: 0.58, blue: 0.20, alpha: 1),
    NSColor(red: 1.00, green: 0.84, blue: 0.20, alpha: 1),
    NSColor(red: 0.30, green: 0.85, blue: 0.45, alpha: 1),
    NSColor(red: 0.20, green: 0.72, blue: 0.95, alpha: 1),
    NSColor(red: 0.29, green: 0.45, blue: 1.00, alpha: 1),
    NSColor(red: 0.65, green: 0.40, blue: 0.95, alpha: 1),
    NSColor(red: 1.00, green: 0.40, blue: 0.70, alpha: 1),
    NSColor(white: 1.00, alpha: 1),
    NSColor(white: 0.55, alpha: 1),
    NSColor(white: 0.10, alpha: 1),
  ]

  override var acceptsFirstResponder: Bool { true }
  override func becomeFirstResponder() -> Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let track { removeTrackingArea(track) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    track = area
  }

  // MARK: 几何

  private var closeBox: NSRect {
    NSRect(x: bounds.maxX - 56, y: bounds.maxY - 56, width: 40, height: 40)
  }

  private func handles() -> [NSRect] {
    guard sel.width > 2, sel.height > 2 else { return [] }
    let s: CGFloat = 8
    let r = sel
    let pts = [
      NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.midX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY),
      NSPoint(x: r.minX, y: r.midY), NSPoint(x: r.maxX, y: r.midY),
      NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.midX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
    ]
    return pts.map { NSRect(x: $0.x - s / 2, y: $0.y - s / 2, width: s, height: s) }
  }

  /// 一级工具条：4 个工具 + 4 个动作
  private func primaryBar() -> (bg: NSRect, tools: [NSRect], actions: [NSRect]) {
    let bh: CGFloat = 36
    let d: CGFloat = 28
    let gap: CGFloat = 6
    let inset: CGFloat = 7
    let w = inset * 2 + d * 9 + gap * 8 + 8
    var x = sel.maxX - w
    var y = sel.minY - bh - 10
    if y < bounds.minY + 8 { y = sel.maxY + 10 }
    y = max(bounds.minY + 8, min(y, bounds.maxY - bh - 8))
    let bg = NSRect(x: x, y: y, width: w, height: bh)
    var cx = bg.minX + inset
    var tools: [NSRect] = []
    for _ in 0..<5 { tools.append(NSRect(x: cx, y: bg.midY - 14, width: d, height: 28)); cx += d + gap }
    cx += 8
    var acts: [NSRect] = []
    for _ in 0..<4 { acts.append(NSRect(x: cx, y: bg.midY - 14, width: d, height: 28)); cx += d + gap }
    return (bg, tools, acts)
  }

  /// 二级工具条：选项在左，颜色块 + ▾ 在最右
  private func secondaryBar() -> (
    bg: NSRect, items: [NSRect], swatch: NSRect, arrow: NSRect, value: NSRect
  )? {
    guard let p = primary, p != .text else { return nil }
    let bh: CGFloat = 34
    let gap: CGFloat = 6
    let inset: CGFloat = 7
    let itemW: CGFloat = 26
    let toggleW: CGFloat = 28
    let sliderW: CGFloat = 76
    let swatchW: CGFloat = 24
    let arrowW: CGFloat = 16
    let valueW: CGFloat = 26
    let segW: CGFloat = 48
    let segGap: CGFloat = 2
    let groupGap: CGFloat = 9

    let w: CGFloat
    switch p {
    case .shape:
      w = inset * 2 + 3 * (itemW + gap) + 2 * (toggleW + gap)
        + sliderW + gap + valueW + gap + 4 + swatchW + 4 + arrowW
    case .mosaic:
      w = inset * 2 + 2 * (segW + segGap) + groupGap + 2 * (segW + segGap) + groupGap
        + sliderW + gap + valueW
    default:
      w = inset * 2 + sliderW + gap + valueW + gap + 4 + swatchW + 4 + arrowW
    }

    let pb = primaryBar()
    var y = pb.bg.minY - bh - 6
    if y < bounds.minY + 8 { y = pb.bg.maxY + 6 }
    y = max(bounds.minY + 8, min(y, bounds.maxY - bh - 8))
    let bg = NSRect(x: sel.maxX - w, y: y, width: w, height: bh)

    var cx = bg.minX + inset
    var items: [NSRect] = []
    var valueRect = NSRect.zero

    switch p {
    case .shape:
      for _ in 0..<3 {
        items.append(NSRect(x: cx, y: bg.midY - 13, width: itemW, height: 26)); cx += itemW + gap
      }
      // 外框 / 粗细 / 填充
      items.append(NSRect(x: cx, y: bg.midY - 13, width: toggleW, height: 26)); cx += toggleW + gap
      items.append(NSRect(x: cx, y: bg.midY - 10, width: sliderW, height: 20)); cx += sliderW + gap
      valueRect = NSRect(x: cx, y: bg.midY - 9, width: valueW, height: 18); cx += valueW + gap
      items.append(NSRect(x: cx, y: bg.midY - 13, width: toggleW, height: 26)); cx += toggleW + gap
    case .mosaic:
      for i in 0..<4 {
        items.append(NSRect(x: cx, y: bg.midY - 12, width: segW, height: 24))
        cx += segW + (i == 1 ? groupGap : segGap)
      }
      items.append(NSRect(x: cx, y: bg.midY - 10, width: sliderW, height: 20)); cx += sliderW + gap
      valueRect = NSRect(x: cx, y: bg.midY - 9, width: valueW, height: 18); cx += valueW
    default:
      items.append(NSRect(x: cx, y: bg.midY - 10, width: sliderW, height: 20)); cx += sliderW + gap
      valueRect = NSRect(x: cx, y: bg.midY - 9, width: valueW, height: 18); cx += valueW + gap
    }

    var swatch = NSRect.zero
    var arrow = NSRect.zero
    if p != .mosaic {
      let sx = bg.maxX - inset - arrowW - 4 - swatchW
      swatch = NSRect(x: sx, y: bg.midY - swatchW / 2, width: swatchW, height: swatchW)
      arrow = NSRect(x: swatch.maxX + 4, y: bg.midY - 12, width: arrowW, height: 24)
    }
    return (bg, items, swatch, arrow, valueRect)
  }

  // MARK: 涂抹粗细三级菜单

  private func brushMenuRect() -> NSRect {
    guard let sb = secondaryBar(), sb.items.count > 2 else { return .zero }
    let target = sb.items[2]
    let w: CGFloat = 120
    let h: CGFloat = 44
    var x = target.midX - w / 2
    var y = sb.bg.minY - h - 6
    if y < bounds.minY + 8 { y = sb.bg.maxY + 6 }
    x = min(max(x, bounds.minX + 8), bounds.maxX - w - 8)
    y = max(bounds.minY + 8, y)
    return NSRect(x: x, y: y, width: w, height: h)
  }

  private func brushDotRects() -> [NSRect] {
    let r = brushMenuRect()
    guard r.width > 0 else { return [] }
    return (0..<3).map { i in
      let cx = r.minX + r.width * (CGFloat(i) + 0.5) / 3
      return NSRect(x: cx - 10, y: r.midY - 10, width: 20, height: 20)
    }
  }

  private let brushSizes: [CGFloat] = [10, 20, 32]

  private func paletteRect() -> NSRect {
    guard let sb = secondaryBar() else { return .zero }
    let cols = 6
    let cell: CGFloat = 24
    let gap: CGFloat = 6
    let rows = Int(ceil(Double(presets.count + 1) / Double(cols)))
    let w = CGFloat(cols) * cell + CGFloat(cols - 1) * gap + 16
    let h = CGFloat(rows) * cell + CGFloat(rows - 1) * gap + 16
    var x = sb.swatch.maxX - w
    var y = sb.bg.minY - h - 6
    if y < bounds.minY + 8 { y = sb.bg.maxY + 6 }
    x = max(bounds.minX + 8, x)
    y = max(bounds.minY + 8, y)
    return NSRect(x: x, y: y, width: w, height: h)
  }

  private func paletteCells() -> [NSRect] {
    let pr = paletteRect()
    let cols = 6
    let cell: CGFloat = 24
    let gap: CGFloat = 6
    var out: [NSRect] = []
    for i in 0..<(presets.count + 1) {
      let r = i / cols, c = i % cols
      out.append(NSRect(
        x: pr.minX + 8 + CGFloat(c) * (cell + gap),
        y: pr.maxY - 8 - cell - CGFloat(r) * (cell + gap),
        width: cell, height: cell))
    }
    return out
  }

  // MARK: 自定义取色（画在同一层遮罩里，不弹独立窗口）

  /// 固定贴工具条右上角向上弹出
  private func customRect() -> NSRect {
    guard let sb = secondaryBar() else { return .zero }
    let w: CGFloat = 216
    let h: CGFloat = 192
    let x = max(bounds.minX + 8, sb.bg.maxX - w)
    let y = min(max(bounds.minY + 8, sb.bg.maxY + 6), bounds.maxY - h - 8)
    return NSRect(x: x, y: y, width: w, height: h)
  }

  private func customSV() -> NSRect {
    let cr = customRect()
    return NSRect(x: cr.minX + 10, y: cr.maxY - 10 - 118, width: cr.width - 20, height: 118)
  }

  private func customHue() -> NSRect {
    let sv = customSV()
    return NSRect(x: sv.minX, y: sv.minY - 8 - 14, width: sv.width, height: 14)
  }

  private func customChip() -> NSRect {
    let cr = customRect()
    return NSRect(x: cr.minX + 10, y: cr.minY + 10, width: 22, height: 22)
  }

  private func syncCustomFromColor() {
    let c = color.usingColorSpace(.sRGB) ?? NSColor.white
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    hueValue = max(0, min(1, h)) * 360
    satValue = max(0, min(1, s))
    brightValue = max(0, min(1, b))
  }

  private func applySV(_ p: NSPoint) {
    let sv = customSV()
    satValue = max(0, min(1, (p.x - sv.minX) / max(sv.width, 1)))
    brightValue = max(0, min(1, (p.y - sv.minY) / max(sv.height, 1)))
    color = NSColor(hue: hueValue / 360, saturation: satValue, brightness: brightValue, alpha: 1)
    needsDisplay = true
  }

  private func applyHue(_ p: NSPoint) {
    let hb = customHue()
    hueValue = max(0, min(1, (p.x - hb.minX) / max(hb.width, 1))) * 360
    color = NSColor(hue: hueValue / 360, saturation: satValue, brightness: brightValue, alpha: 1)
    needsDisplay = true
  }

  private func hexString() -> String {
    let c = color.usingColorSpace(.sRGB) ?? NSColor.white
    return String(
      format: "#%02X%02X%02X",
      Int(max(0, min(1, c.redComponent)) * 255 + 0.5),
      Int(max(0, min(1, c.greenComponent)) * 255 + 0.5),
      Int(max(0, min(1, c.blueComponent)) * 255 + 0.5))
  }

  // MARK: 交互

  override func mouseDown(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    setTip(nil, .zero)
    if closeBox.contains(p) { onCancel?(); return }

    // 自定义取色优先
    if showCustom {
      let sv = customSV(), hb = customHue()
      if sv.insetBy(dx: -3, dy: -3).contains(p) { customDrag = .sv; applySV(p); return }
      if hb.insetBy(dx: -4, dy: -7).contains(p) { customDrag = .hue; applyHue(p); return }
      if customRect().contains(p) { return }
      showCustom = false
      needsDisplay = true
    }

    // 颜色弹层优先
    if showPalette {
      let cells = paletteCells()
      for (i, r) in cells.enumerated() where r.contains(p) {
        if i < presets.count {
          color = presets[i]
          showPalette = false
        } else {
          if showCustom {
            showCustom = false
          } else {
            syncCustomFromColor()
            showCustom = true
          }
        }
        needsDisplay = true
        return
      }
      showPalette = false
      needsDisplay = true
      return
    }

    if sel.width > 4, sel.height > 4 {
      // 涂抹粗细菜单优先
      if showBrushMenu {
        for (i, r) in brushDotRects().enumerated() where r.contains(p) {
          brushSize = brushSizes[i]
          showBrushMenu = false
          needsDisplay = true
          return
        }
        if !brushMenuRect().contains(p) {
          showBrushMenu = false
          needsDisplay = true
        }
      }

      // 二级栏
      if let sb = secondaryBar() {
        if primary != .mosaic, sb.swatch.insetBy(dx: -2, dy: -2).contains(p) {
          showPalette.toggle()
          needsDisplay = true
          return
        }
        if primary != .mosaic, sb.arrow.insetBy(dx: -2, dy: -2).contains(p) {
          showPalette = true
          needsDisplay = true
          return
        }
        for (i, r) in sb.items.enumerated() where r.insetBy(dx: -2, dy: -2).contains(p) {
          handleSecondaryItem(i, p)
          return
        }
      }
      // 一级栏
      let pb = primaryBar()
      for (i, r) in pb.tools.enumerated() where r.insetBy(dx: -2, dy: -2).contains(p) {
        selectPrimary(i)
        return
      }
      for (i, r) in pb.actions.enumerated() where r.insetBy(dx: -3, dy: -3).contains(p) {
        switch i {
        case 0: undo()
        case 1: onCancel?()
        case 2: onSave?(sel, self)
        default: onConfirm?(sel, self)
        }
        return
      }

      if let t = tool, sel.contains(p) {
        var a = Annotation(
          tool: t, points: [p, p], color: color,
          width: t.isMosaic ? brushSize : lineWidth,
          filled: shapeFilled, outline: !shapeFilled)
        a.block = mosaicBlock
        a.blur = mosaicBlur
        draft = a
        needsDisplay = true
        return
      }
      if !selLocked {
        for (i, hnd) in handles().enumerated() where hnd.insetBy(dx: -6, dy: -6).contains(p) {
          resizeHandle = i
          moveStart = p
          moveOrigin = sel
          return
        }
        if sel.contains(p) {
          resizeHandle = 8
          moveStart = p
          moveOrigin = sel
          NSCursor.closedHand.set()
          return
        }
      }
      return
    }

    resizeHandle = -1
    dragging = true
    dragStart = p
    selBefore = sel
    sel = NSRect(origin: p, size: .zero)
    pressAt = p
    moved = false
    needsDisplay = true
  }

  private func selectPrimary(_ i: Int) {
    guard let p = Primary(rawValue: i) else { return }
    if primary == p {
      primary = nil
      tool = nil
    } else {
      primary = p
      switch p {
      case .shape: tool = shapeKind
      case .arrow: tool = .arrow
      case .pen: tool = .pen
      case .text: tool = nil
      case .mosaic: tool = mosaicBrushMode ? .mosaicBrush : .mosaicRect
      }
    }
    draft = nil
    showPalette = false
    showCustom = false
    showBrushMenu = false
    needsDisplay = true
  }

  private func handleSecondaryItem(_ i: Int, _ p: NSPoint) {
    guard let primary else { return }
    if primary == .shape {
      if i < 3 {
        let kinds: [ShotTool] = [.rect, .ellipse, .line]
        shapeKind = kinds[i]
        tool = shapeKind
        if shapeKind == .line { shapeFilled = false }
        needsDisplay = true
        return
      }
      if i == 3 {
        shapeFilled = false
      } else if i == 5 {
        if shapeKind == .line { return }
        shapeFilled = true
      } else if i == 4 {
        if shapeFilled { return }
        sliderDrag = true
        applySlider(p)
      }
      needsDisplay = true
    } else if primary == .mosaic {
      switch i {
      case 0: mosaicBlur = false
      case 1: mosaicBlur = true
      case 2:
        mosaicBrushMode = true
        tool = .mosaicBrush
        showBrushMenu = true
      case 3:
        mosaicBrushMode = false
        tool = .mosaicRect
        showBrushMenu = false
      default:
        sliderDrag = true
        applyMosaicSlider(p)
      }
      needsDisplay = true
    } else {
      sliderDrag = true
      applySlider(p)
    }
  }

  private func sliderRect() -> NSRect? {
    guard primary != nil, let sb = secondaryBar() else { return nil }
    if primary == .shape { return sb.items.count > 4 ? sb.items[4] : nil }
    if primary == .mosaic { return sb.items.count > 4 ? sb.items[4] : nil }
    return sb.items.first
  }

  private func applyMosaicSlider(_ p: NSPoint) {
    guard let r = sliderRect() else { return }
    let t = max(0, min(1, (p.x - r.minX) / max(r.width, 1)))
    mosaicBlock = max(1, min(10, (1 + t * 9).rounded()))   // 1…10，步进 1
    mosaicFrameCache = nil
    needsDisplay = true
  }

  private func applySlider(_ p: NSPoint) {
    guard let r = sliderRect() else { return }
    let t = max(0, min(1, (p.x - r.minX) / max(r.width, 1)))
    lineWidth = 1 + t * 11
    needsDisplay = true
  }

  private func undo() {
    guard let last = annotations.popLast() else { NSSound.beep(); return }
    redoStack.append(last)
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    if customDrag != .none {
      if customDrag == .sv { applySV(p) } else { applyHue(p) }
      return
    }
    if sliderDrag {
      if primary == .mosaic { applyMosaicSlider(p) } else { applySlider(p) }
      return
    }
    if var d = draft {
      if d.tool == .pen || d.tool == .mosaicBrush { d.points.append(p) } else { d.points[1] = p }
      draft = d
      needsDisplay = true
      return
    }
    if dragging, abs(p.x - pressAt.x) > 1.5 || abs(p.y - pressAt.y) > 1.5 {
      moved = true
      hoverRect = .zero
      hoverID = 0
    }
    if resizeHandle == -1, dragging {
      sel = NSRect(
        x: min(dragStart.x, p.x), y: min(dragStart.y, p.y),
        width: abs(p.x - dragStart.x), height: abs(p.y - dragStart.y))
    } else if resizeHandle == 8 {
      sel = moveOrigin.offsetBy(dx: p.x - moveStart.x, dy: p.y - moveStart.y)
    } else if resizeHandle >= 0 {
      var r = moveOrigin
      let dx = p.x - moveStart.x
      let dy = p.y - moveStart.y
      switch resizeHandle {
      case 0: r.origin.x += dx; r.size.width -= dx; r.size.height += dy
      case 1: r.size.height += dy
      case 2: r.size.width += dx; r.size.height += dy
      case 3: r.origin.x += dx; r.size.width -= dx
      case 4: r.size.width += dx
      case 5: r.origin.x += dx; r.size.width -= dx; r.origin.y += dy; r.size.height -= dy
      case 6: r.origin.y += dy; r.size.height -= dy
      case 7: r.size.width += dx; r.origin.y += dy; r.size.height -= dy
      default: break
      }
      if r.size.width > 1, r.size.height > 1 { sel = r }
    }
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    customDrag = .none
    sliderDrag = false
    if let d = draft {
      if d.tool == .pen || d.tool == .mosaicBrush {
        if d.points.count > 1 { annotations.append(d); redoStack.removeAll() }
      } else if abs(d.points[1].x - d.points[0].x) > 2 || abs(d.points[1].y - d.points[0].y) > 2 {
        annotations.append(d)
        redoStack.removeAll()
      }
      draft = nil
      needsDisplay = true
      return
    }
    let wasDragging = dragging
    dragging = false
    resizeHandle = -1
    if wasDragging && !moved && hoverRect.width > 4 {
      sel = hoverRect
      selWindowID = hoverID
    } else if sel.width < 4 || sel.height < 4 {
      sel = selBefore
      selWindowID = 0
    } else {
      selWindowID = 0
    }
    needsDisplay = true
  }

  override func rightMouseDown(with event: NSEvent) { onCancel?() }

  override func mouseMoved(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    updateCursor(p)
    if sel.width > 4, sel.height > 4 { return }
    if let hit = windowUnder(p) {
      if hit.rect != hoverRect || hit.id != hoverID {
        hoverRect = hit.rect
        hoverID = hit.id
        needsDisplay = true
      }
    } else if hoverID != 0 {
      hoverRect = .zero
      hoverID = 0
      needsDisplay = true
    }
  }

  private func windowUnder(_ p: NSPoint) -> (rect: NSRect, id: CGWindowID)? {
    guard let screen = window?.screen else { return nil }
    let list = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    let mainH = CGDisplayBounds(CGMainDisplayID()).height
    let myPID = Int(getpid())
    for info in list ?? [] {
      guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
      guard let pid = info[kCGWindowOwnerPID as String] as? Int, pid != myPID else { continue }
      guard let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0.05 else { continue }
      guard let dict = info[kCGWindowBounds as String] as? NSDictionary,
            let g = CGRect(dictionaryRepresentation: dict) else { continue }
      if g.width < 40 || g.height < 40 { continue }
      let ay = mainH - g.minY - g.height
      let rect = NSRect(
        x: g.minX - screen.frame.origin.x, y: ay - screen.frame.origin.y,
        width: g.width, height: g.height)
      if rect.contains(p) { return (rect, CGWindowID(info[kCGWindowNumber as String] as? UInt32 ?? 0)) }
    }
    return nil
  }

  private func diagonal(_ name: String) -> NSCursor {
    if let c = NSCursor.perform(NSSelectorFromString(name))?.takeUnretainedValue() as? NSCursor {
      return c
    }
    return NSCursor.resizeLeftRight
  }

  // MARK: 马赛克预览

  /// 只对选区附近做滤镜，返回（图像, 绘制矩形）
  private func pixelatedFrame(block: CGFloat, blur: Bool) -> (NSImage, NSRect)? {
    guard screenImage != nil, sel.width > 1, sel.height > 1 else { return nil }
    let region = sel.insetBy(dx: -60, dy: -60).intersection(bounds)
    let key = "\(Int(block))-\(blur)-\(Int(region.minX))-\(Int(region.minY))-\(Int(region.width))-\(Int(region.height))"
    if let c = mosaicFrameCache, c.key == key { return (c.image, region) }

    guard let rep = renderRegion(region), let cg = rep.cgImage else { return nil }
    let base = CIImage(cgImage: cg)
    let extent = base.extent
    let scale = max(window?.backingScaleFactor ?? 1, 1)
    var out: CIImage
    if blur {
      out = base.clampedToExtent()
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: block * scale])
        .cropped(to: extent)
    } else {
      out = base
        .applyingFilter("CIPixellate", parameters: [
          kCIInputScaleKey: block * scale,
          kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
        ])
        .cropped(to: extent)
    }
    guard let result = ciContext.createCGImage(out, from: extent) else { return nil }
    let image = NSImage(cgImage: result, size: region.size)
    mosaicFrameCache = (key, image)
    return (image, region)
  }

  private func drawMosaicPreview(_ a: Annotation) {
    guard let path = mosaicClipPath(a), let ctx = NSGraphicsContext.current?.cgContext else { return }
    let box = mosaicBounds(a)
    guard box.width > 0.5, box.height > 0.5 else { return }
    ctx.saveGState()
    if a.tool == .mosaicBrush {
      ctx.addPath(path)
      ctx.setLineWidth(a.width)
      ctx.setLineCap(.round)
      ctx.setLineJoin(.round)
      ctx.replacePathWithStrokedPath()
      ctx.clip()
    } else {
      ctx.addPath(path)
      ctx.clip()
    }
    if let (img, region) = pixelatedFrame(block: a.block, blur: a.blur) {
      img.draw(in: region)
    } else {
      // 还没截到图：占位斜纹
      NSColor(white: 0.55, alpha: 0.45).setFill()
      box.fill()
    }
    ctx.restoreGState()
  }

  // MARK: 底图（打开截图时先截好的整屏图）

  private var screenImage: NSImage?
  private var markedFirstDraw = false

  func setBaseImage(_ img: NSImage?) {
    screenImage = img
    mosaicFrameCache = nil
    needsDisplay = true
  }

  /// 把内存里的整屏图按选区"画"出来（与屏幕同一套绘制方式，不会错位）
  func frozenCrop(_ rect: NSRect) -> Data? {
    guard let img = screenImage, rect.width > 1, rect.height > 1 else { return nil }
    guard let rep = renderRegion(rect) else { return nil }
    _ = img
    return rep.representation(using: .png, properties: [:])
  }

  /// 用屏幕同一套映射把 rect 区域渲染成位图（设备像素）
  private func renderRegion(_ rect: NSRect) -> NSBitmapImageRep? {
    guard let img = screenImage else { return nil }
    let scale = max(window?.backingScaleFactor ?? 1, 1)
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: max(1, Int((rect.width * scale).rounded())),
      pixelsHigh: max(1, Int((rect.height * scale).rounded())),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    // 必须在建 context 之前设 size：否则 CTM 按 1 点 = 1 像素，图只画到左下角
    rep.size = rect.size
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
    img.draw(in: bounds)
    NSGraphicsContext.restoreGraphicsState()
    return rep
  }


  private func setTip(_ text: String?, _ anchor: NSRect) {
    if tipText != text || tipAnchor != anchor {
      tipText = text
      tipAnchor = anchor
      needsDisplay = true
    }
  }

  /// 鼠标停在工具按钮上时给出名字
  private func updateTip(_ p: NSPoint) {
    guard sel.width > 4, sel.height > 4 else { setTip(nil, .zero); return }
    let pb = primaryBar()
    for (i, r) in pb.tools.enumerated() where r.insetBy(dx: -2, dy: -2).contains(p) {
      setTip(["形状", "箭头", "画笔", "文字（未实现）", "马赛克"][i], r)
      return
    }
    for (i, r) in pb.actions.enumerated() where r.insetBy(dx: -2, dy: -2).contains(p) {
      setTip(["撤销 ⌘Z", "取消 Esc", "保存到桌面", "完成 ⏎"][i], r)
      return
    }
    if let sb = secondaryBar() {
      if sb.swatch.insetBy(dx: -2, dy: -2).contains(p) { setTip("颜色", sb.swatch); return }
      if sb.arrow.insetBy(dx: -2, dy: -2).contains(p) { setTip("更多颜色", sb.arrow); return }
      if let idx = sb.items.firstIndex(where: { $0.insetBy(dx: -2, dy: -2).contains(p) }) {
        let shapeNames = ["矩形", "圆形", "画线", "外框", "粗细", "填充"]
        let mosaicNames = ["马赛克", "模糊", "涂抹（点击选粗细）", "框选", mosaicBlur ? "模糊半径" : "像素大小"]
        var name = "粗细"
        if primary == .shape, idx < shapeNames.count { name = shapeNames[idx] }
        if primary == .mosaic, idx < mosaicNames.count { name = mosaicNames[idx] }
        setTip(name, sb.items[idx])
        return
      }
    }
    setTip(nil, .zero)
  }

  override func mouseExited(with event: NSEvent) { setTip(nil, .zero) }

  private func updateCursor(_ p: NSPoint) {
    updateTip(p)
    guard sel.width > 4, sel.height > 4 else { NSCursor.crosshair.set(); return }
    var rects: [NSRect] = []
    if showCustom { rects += [customSV(), customHue()] }
    if showPalette { rects += paletteCells() }
    let pb = primaryBar()
    rects += pb.tools + pb.actions
    if let sb = secondaryBar() {
      rects += sb.items
      if primary != .mosaic { rects += [sb.swatch, sb.arrow] }
    }
    if rects.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(p) }) {
      NSCursor.pointingHand.set()
      return
    }
    if tool != nil { NSCursor.crosshair.set(); return }
    if !selLocked,
       let idx = handles().enumerated().first(where: {
         $0.element.insetBy(dx: -6, dy: -6).contains(p)
       })?.offset {
      switch idx {
      case 0, 7: diagonal("_windowResizeNorthWestSouthEastCursor").set()
      case 2, 5: diagonal("_windowResizeNorthEastSouthWestCursor").set()
      case 1, 6: NSCursor.resizeUpDown.set()
      case 3, 4: NSCursor.resizeLeftRight.set()
      default: NSCursor.crosshair.set()
      }
      return
    }
    if !selLocked, sel.contains(p) { NSCursor.openHand.set(); return }
    NSCursor.crosshair.set()
  }

  override func keyDown(with event: NSEvent) {
    let scale = max(window?.backingScaleFactor ?? 1, 1)
    let step = (event.modifierFlags.contains(.shift) ? 1.0 : 5.0) / scale
    if event.modifierFlags.contains(.command), event.keyCode == 6 {
      if event.modifierFlags.contains(.shift) {
        if let last = redoStack.popLast() { annotations.append(last) }
      } else if let last = annotations.popLast() {
        redoStack.append(last)
      }
      needsDisplay = true
      return
    }
    switch event.keyCode {
    case 123:
      guard !selLocked, sel.width > step else { return }
      sel.size.width -= step; needsDisplay = true
    case 124:
      guard !selLocked else { return }
      sel.size.width += step; needsDisplay = true
    case 125:
      guard !selLocked else { return }
      sel.origin.y -= step; sel.size.height += step; needsDisplay = true
    case 126:
      guard !selLocked, sel.height > step else { return }
      sel.origin.y += step; sel.size.height -= step; needsDisplay = true
    case 53:
      if showCustom { showCustom = false; needsDisplay = true }
      else if showPalette { showPalette = false; needsDisplay = true }
      else if primary != nil { primary = nil; tool = nil; needsDisplay = true }
      else { onCancel?() }
    case 36, 76: if sel.width > 4, sel.height > 4 { onConfirm?(sel, self) }
    default: super.keyDown(with: event)
    }
  }

  override func cancelOperation(_ sender: Any?) { onCancel?() }

  override func draw(_ dirtyRect: NSRect) {
    if !markedFirstDraw {
      markedFirstDraw = true
      ScreenshotOverlay.openMark("first draw")
    }
    // 底图整画一次，再用"整屏减去选区"的遮罩压暗，天然对齐
    if let img = screenImage {
      img.draw(in: bounds)
      if sel.width > 4, sel.height > 4 {
        let mask = NSBezierPath(rect: bounds)
        mask.append(NSBezierPath(rect: sel))
        mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.45).setFill()
        mask.fill()
      } else {
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()
      }
    } else {
      NSColor.black.withAlphaComponent(0.45).setFill()
      bounds.fill()
    }

    if sel.width <= 4 || sel.height <= 4 {
      if hoverRect.width > 4 {
        // 只在鼠标确实位于这块屏幕上时才画，避免副屏出现"幽灵框"
        let mp = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) } ?? .zero
        if bounds.contains(mp) {
          NSColor(red: 0.29, green: 0.56, blue: 1.0, alpha: 1).setStroke()
          let hp = NSBezierPath(rect: hoverRect)
          hp.lineWidth = 2
          hp.stroke()
        }
      }
    } else {
      NSGraphicsContext.saveGraphicsState()
      NSBezierPath(rect: sel).addClip()
      for a in annotations {
        if a.tool.isMosaic { drawMosaicPreview(a) } else { drawAnnotation(a) }
      }
      if let d = draft {
        if d.tool.isMosaic { drawMosaicPreview(d) } else { drawAnnotation(d) }
      }
      NSGraphicsContext.restoreGraphicsState()

      // 框选马赛克：拖动时给个蓝框提示，松手就没了
      if let d = draft, d.tool == .mosaicRect, d.points.count >= 2 {
        let r = NSRect(
          x: min(d.points[0].x, d.points[1].x), y: min(d.points[0].y, d.points[1].y),
          width: abs(d.points[1].x - d.points[0].x), height: abs(d.points[1].y - d.points[0].y))
        if r.width > 1, r.height > 1 {
          NSColor(red: 0.29, green: 0.56, blue: 1.0, alpha: 1).setStroke()
          let bp = NSBezierPath(rect: r)
          bp.lineWidth = 1.5
          bp.stroke()
        }
      }

      NSColor.white.setStroke()
      let border = NSBezierPath(rect: sel)
      border.lineWidth = 1
      border.stroke()
      NSColor.white.setFill()
      if !selLocked { for hnd in handles() { hnd.fill() } }

      let label = "\(Int(sel.width)) × \(Int(sel.height))"
      let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.white,
      ]
      let size = (label as NSString).size(withAttributes: attrs)
      var lx = sel.midX - size.width / 2
      var ly = sel.maxY + 6
      if ly + size.height > bounds.maxY { ly = sel.minY - size.height - 6 }
      lx = min(max(lx, bounds.minX + 4), bounds.maxX - size.width - 4)
      if ly < bounds.minY { ly = bounds.minY + 4 }
      let box = NSRect(x: lx - 6, y: ly - 2, width: size.width + 12, height: size.height + 4)
      NSColor.black.withAlphaComponent(0.6).setFill()
      NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
      (label as NSString).draw(at: NSPoint(x: lx, y: ly), withAttributes: attrs)

      drawBars()

      if let tip = tipText {
        let attrs: [NSAttributedString.Key: Any] = [
          .font: NSFont.systemFont(ofSize: 11, weight: .medium),
          .foregroundColor: NSColor(white: 0.96, alpha: 1),
        ]
        let ts = (tip as NSString).size(withAttributes: attrs)
        var ty = tipAnchor.minY - ts.height - 10
        if ty < bounds.minY + 4 { ty = tipAnchor.maxY + 10 }
        let bw = ts.width + 14
        let bx = min(max(tipAnchor.midX - bw / 2, bounds.minX + 4), bounds.maxX - bw - 4)
        let box = NSRect(x: bx, y: ty, width: bw, height: ts.height + 8)
        NSColor(white: 0.08, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        (tip as NSString).draw(
          at: NSPoint(x: box.minX + 7, y: box.minY + 4), withAttributes: attrs)
      }
    }

    let hint = primary == nil
      ? "拖动选区 · 回车确认 · Esc / 右键取消"
      : "画完按 Esc 退出当前工具"
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 13),
      .foregroundColor: NSColor.white,
    ]
    let hs = (hint as NSString).size(withAttributes: attrs)
    let hx = bounds.midX - hs.width / 2
    let hy = bounds.maxY - 44
    NSColor.black.withAlphaComponent(0.55).setFill()
    NSBezierPath(
      roundedRect: NSRect(x: hx - 10, y: hy - 6, width: hs.width + 20, height: hs.height + 12),
      xRadius: 6, yRadius: 6
    ).fill()
    (hint as NSString).draw(at: NSPoint(x: hx, y: hy), withAttributes: attrs)

    NSColor.black.withAlphaComponent(0.55).setFill()
    NSBezierPath(ovalIn: closeBox).fill()
    let xa: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
      .foregroundColor: NSColor.white,
    ]
    let xs = ("✕" as NSString).size(withAttributes: xa)
    ("✕" as NSString).draw(
      at: NSPoint(x: closeBox.midX - xs.width / 2, y: closeBox.midY - xs.height / 2),
      withAttributes: xa)
  }


  // MARK: 图标（由 SVG 路径直接转换，1024×1024 坐标系，y 轴向下）

  private static let arrowGlyph: NSBezierPath = {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: 768, y: 256))
    p.line(to: NSPoint(x: 353.984, y: 256))
    p.curve(to: NSPoint(x: 330.944, y: 247.04), controlPoint1: NSPoint(x: 345.397, y: 256.317), controlPoint2: NSPoint(x: 337.061, y: 253.075))
    p.curve(to: NSPoint(x: 321.984, y: 224), controlPoint1: NSPoint(x: 324.909, y: 240.923), controlPoint2: NSPoint(x: 321.667, y: 232.587))
    p.curve(to: NSPoint(x: 330.944, y: 200.96), controlPoint1: NSPoint(x: 321.984, y: 214.656), controlPoint2: NSPoint(x: 324.992, y: 206.976))
    p.curve(to: NSPoint(x: 353.984, y: 192), controlPoint1: NSPoint(x: 337.061, y: 194.925), controlPoint2: NSPoint(x: 345.397, y: 191.683))
    p.line(to: NSPoint(x: 800, y: 192))
    p.curve(to: NSPoint(x: 823.04, y: 200.96), controlPoint1: NSPoint(x: 809.344, y: 192), controlPoint2: NSPoint(x: 817.024, y: 195.008))
    p.curve(to: NSPoint(x: 832, y: 224), controlPoint1: NSPoint(x: 828.992, y: 206.976), controlPoint2: NSPoint(x: 832, y: 214.656))
    p.line(to: NSPoint(x: 832, y: 672))
    p.curve(to: NSPoint(x: 823.04, y: 695.04), controlPoint1: NSPoint(x: 832.317, y: 680.587), controlPoint2: NSPoint(x: 829.075, y: 688.923))
    p.curve(to: NSPoint(x: 800, y: 704), controlPoint1: NSPoint(x: 816.923, y: 701.075), controlPoint2: NSPoint(x: 808.587, y: 704.317))
    p.curve(to: NSPoint(x: 776.96, y: 695.04), controlPoint1: NSPoint(x: 791.413, y: 704.317), controlPoint2: NSPoint(x: 783.077, y: 701.075))
    p.curve(to: NSPoint(x: 768, y: 672), controlPoint1: NSPoint(x: 770.925, y: 688.923), controlPoint2: NSPoint(x: 767.683, y: 680.587))
    p.line(to: NSPoint(x: 768, y: 256))
    p.close()
    p.move(to: NSPoint(x: 776.96, y: 200.96))
    p.curve(to: NSPoint(x: 800, y: 192), controlPoint1: NSPoint(x: 783.212, y: 195.137), controlPoint2: NSPoint(x: 791.457, y: 191.931))
    p.curve(to: NSPoint(x: 822.464, y: 201.472), controlPoint1: NSPoint(x: 808.474, y: 191.924), controlPoint2: NSPoint(x: 816.603, y: 195.351))
    p.curve(to: NSPoint(x: 832, y: 224), controlPoint1: NSPoint(x: 828.624, y: 207.337), controlPoint2: NSPoint(x: 832.077, y: 215.494))
    p.curve(to: NSPoint(x: 823.04, y: 247.04), controlPoint1: NSPoint(x: 832.069, y: 232.543), controlPoint2: NSPoint(x: 828.863, y: 240.788))
    p.line(to: NSPoint(x: 279.04, y: 791.04))
    p.curve(to: NSPoint(x: 256, y: 800), controlPoint1: NSPoint(x: 272.788, y: 796.863), controlPoint2: NSPoint(x: 264.543, y: 800.069))
    p.curve(to: NSPoint(x: 233.472, y: 790.464), controlPoint1: NSPoint(x: 247.494, y: 800.077), controlPoint2: NSPoint(x: 239.337, y: 796.624))
    p.curve(to: NSPoint(x: 224, y: 768), controlPoint1: NSPoint(x: 227.351, y: 784.603), controlPoint2: NSPoint(x: 223.924, y: 776.474))
    p.curve(to: NSPoint(x: 232.96, y: 744.96), controlPoint1: NSPoint(x: 224, y: 759.36), controlPoint2: NSPoint(x: 227.008, y: 751.68))
    p.line(to: NSPoint(x: 776.96, y: 200.96))
    p.close()
    return p
  }()

  private static let penGlyph: NSBezierPath = {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: 951.021, y: 210.291))
    p.line(to: NSPoint(x: 763.818, y: 20.5923))
    p.curve(to: NSPoint(x: 663.977, y: 20.5923), controlPoint1: NSPoint(x: 736.362, y: -6.86411), controlPoint2: NSPoint(x: 691.433, y: -6.86411))
    p.line(to: NSPoint(x: 531.687, y: 155.378))
    p.curve(to: NSPoint(x: 529.191, y: 160.371), controlPoint1: NSPoint(x: 529.191, y: 157.874), controlPoint2: NSPoint(x: 529.191, y: 157.874))
    p.line(to: NSPoint(x: 172.257, y: 522.296))
    p.curve(to: NSPoint(x: 164.769, y: 534.776), controlPoint1: NSPoint(x: 169.761, y: 524.792), controlPoint2: NSPoint(x: 164.769, y: 529.784))
    p.line(to: NSPoint(x: 52.4473, y: 884.222))
    p.curve(to: NSPoint(x: 59.9354, y: 916.67), controlPoint1: NSPoint(x: 49.9512, y: 896.702), controlPoint2: NSPoint(x: 52.4473, y: 909.182))
    p.curve(to: NSPoint(x: 92.3839, y: 924.158), controlPoint1: NSPoint(x: 67.4235, y: 924.158), controlPoint2: NSPoint(x: 79.9037, y: 929.151))
    p.line(to: NSPoint(x: 446.821, y: 816.829))
    p.line(to: NSPoint(x: 461.798, y: 809.341))
    p.line(to: NSPoint(x: 821.227, y: 442.423))
    p.curve(to: NSPoint(x: 823.723, y: 437.431), controlPoint1: NSPoint(x: 823.723, y: 439.927), controlPoint2: NSPoint(x: 823.723, y: 439.927))
    p.line(to: NSPoint(x: 953.517, y: 307.637))
    p.curve(to: NSPoint(x: 973.486, y: 257.716), controlPoint1: NSPoint(x: 965.998, y: 295.157), controlPoint2: NSPoint(x: 973.486, y: 277.684))
    p.curve(to: NSPoint(x: 951.021, y: 210.291), controlPoint1: NSPoint(x: 973.486, y: 240.244), controlPoint2: NSPoint(x: 965.998, y: 222.771))
    p.close()
    p.move(to: NSPoint(x: 297.059, y: 714.491))
    p.line(to: NSPoint(x: 379.428, y: 714.491))
    p.line(to: NSPoint(x: 394.405, y: 769.404))
    p.line(to: NSPoint(x: 132.321, y: 846.781))
    p.line(to: NSPoint(x: 217.186, y: 584.697))
    p.line(to: NSPoint(x: 264.611, y: 594.681))
    p.line(to: NSPoint(x: 264.611, y: 679.547))
    p.curve(to: NSPoint(x: 274.595, y: 702.011), controlPoint1: NSPoint(x: 264.611, y: 687.035), controlPoint2: NSPoint(x: 267.107, y: 697.019))
    p.curve(to: NSPoint(x: 297.059, y: 714.491), controlPoint1: NSPoint(x: 279.587, y: 709.499), controlPoint2: NSPoint(x: 287.075, y: 714.491))
    p.close()
    p.move(to: NSPoint(x: 259.618, y: 527.288))
    p.line(to: NSPoint(x: 559.143, y: 225.268))
    p.line(to: NSPoint(x: 753.834, y: 422.455))
    p.line(to: NSPoint(x: 451.813, y: 729.467))
    p.line(to: NSPoint(x: 429.349, y: 649.594))
    p.line(to: NSPoint(x: 329.508, y: 649.594))
    p.line(to: NSPoint(x: 329.508, y: 547.257))
    p.line(to: NSPoint(x: 259.618, y: 527.288))
    p.close()
    p.move(to: NSPoint(x: 908.589, y: 260.212))
    p.curve(to: NSPoint(x: 906.093, y: 265.204), controlPoint1: NSPoint(x: 908.589, y: 262.708), controlPoint2: NSPoint(x: 908.589, y: 262.708))
    p.line(to: NSPoint(x: 796.267, y: 375.03))
    p.line(to: NSPoint(x: 601.576, y: 177.843))
    p.line(to: NSPoint(x: 711.402, y: 65.521))
    p.curve(to: NSPoint(x: 718.89, y: 65.521), controlPoint1: NSPoint(x: 713.898, y: 63.025), controlPoint2: NSPoint(x: 716.394, y: 63.025))
    p.line(to: NSPoint(x: 906.093, y: 255.22))
    p.curve(to: NSPoint(x: 908.589, y: 260.212), controlPoint1: NSPoint(x: 906.093, y: 257.716), controlPoint2: NSPoint(x: 908.589, y: 257.716))
    p.close()
    p.move(to: NSPoint(x: 49.9512, y: 949.119))
    p.line(to: NSPoint(x: 973.486, y: 949.119))
    p.line(to: NSPoint(x: 973.486, y: 1024))
    p.line(to: NSPoint(x: 49.9512, y: 1024))
    p.line(to: NSPoint(x: 49.9512, y: 949.119))
    p.close()
    return p
  }()

  private static let undoGlyph: NSBezierPath = {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: 352.65, y: 354))
    p.line(to: NSPoint(x: 473.99, y: 475.34))
    p.curve(to: NSPoint(x: 473.99, y: 517.767), controlPoint1: NSPoint(x: 485.706, y: 487.056), controlPoint2: NSPoint(x: 485.706, y: 506.05))
    p.curve(to: NSPoint(x: 431.563, y: 517.767), controlPoint1: NSPoint(x: 462.274, y: 529.482), controlPoint2: NSPoint(x: 443.28, y: 529.482))
    p.line(to: NSPoint(x: 256.201, y: 342.404))
    p.curve(to: NSPoint(x: 256.201, y: 297.149), controlPoint1: NSPoint(x: 243.704, y: 329.907), controlPoint2: NSPoint(x: 243.704, y: 309.646))
    p.line(to: NSPoint(x: 431.563, y: 121.787))
    p.curve(to: NSPoint(x: 473.99, y: 121.787), controlPoint1: NSPoint(x: 443.279, y: 110.071), controlPoint2: NSPoint(x: 462.274, y: 110.071))
    p.curve(to: NSPoint(x: 473.99, y: 164.213), controlPoint1: NSPoint(x: 485.706, y: 133.503), controlPoint2: NSPoint(x: 485.706, y: 152.497))
    p.line(to: NSPoint(x: 344.203, y: 294))
    p.line(to: NSPoint(x: 687, y: 294))
    p.curve(to: NSPoint(x: 939, y: 546), controlPoint1: NSPoint(x: 826.176, y: 294), controlPoint2: NSPoint(x: 939, y: 406.824))
    p.curve(to: NSPoint(x: 687, y: 798), controlPoint1: NSPoint(x: 939, y: 685.176), controlPoint2: NSPoint(x: 826.176, y: 798))
    p.line(to: NSPoint(x: 115, y: 798))
    p.curve(to: NSPoint(x: 85, y: 768), controlPoint1: NSPoint(x: 98.431, y: 798), controlPoint2: NSPoint(x: 85, y: 784.569))
    p.curve(to: NSPoint(x: 115, y: 738), controlPoint1: NSPoint(x: 85, y: 751.431), controlPoint2: NSPoint(x: 98.431, y: 738))
    p.line(to: NSPoint(x: 687, y: 738))
    p.curve(to: NSPoint(x: 879, y: 546), controlPoint1: NSPoint(x: 793.039, y: 738), controlPoint2: NSPoint(x: 879, y: 652.039))
    p.curve(to: NSPoint(x: 687, y: 354), controlPoint1: NSPoint(x: 879, y: 439.961), controlPoint2: NSPoint(x: 793.039, y: 354))
    p.line(to: NSPoint(x: 352.65, y: 354))
    p.close()
    return p
  }()

  /// 把 1024 坐标系下的路径等比放进 rect 并填充
  private func fillGlyph(_ glyph: NSBezierPath, in rect: NSRect, _ color: NSColor) {
    let b = glyph.bounds
    guard b.width > 0, b.height > 0 else { return }
    let s = min(rect.width / b.width, rect.height / b.height)
    let m = AffineTransform(
      m11: s, m12: 0, m21: 0, m22: -s,
      tX: rect.midX - s * b.midX, tY: rect.midY + s * b.midY)
    let p = glyph.copy() as! NSBezierPath
    p.transform(using: m)
    color.setFill()
    p.fill()
  }

  private func drawBars() {
    let white = NSColor(white: 0.94, alpha: 1)
    let red = NSColor(red: 1.0, green: 0.32, blue: 0.28, alpha: 1)
    let green = NSColor(red: 0.30, green: 0.85, blue: 0.45, alpha: 1)

    // 一级
    let pb = primaryBar()
    NSColor(white: 0.12, alpha: 0.94).setFill()
    NSBezierPath(roundedRect: pb.bg, xRadius: 8, yRadius: 8).fill()

    for (i, r) in pb.tools.enumerated() {
      if primary?.rawValue == i {
        NSColor(white: 0.30, alpha: 1).setFill()
        NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 5), xRadius: 5, yRadius: 5).fill()
      }
      white.setStroke()
      white.setFill()
      let mid = NSPoint(x: r.midX, y: r.midY)
      switch i {
      case 0:  // 形状：方框 + 圆（原版）
        let sq = NSBezierPath(roundedRect: NSRect(
          x: mid.x - 7, y: mid.y - 6, width: 10, height: 9), xRadius: 1.5, yRadius: 1.5)
        sq.lineWidth = 1.6
        sq.lineCapStyle = .round
        white.setStroke()
        sq.stroke()
        let ci = NSBezierPath(ovalIn: NSRect(x: mid.x - 1, y: mid.y - 1, width: 8, height: 8))
        ci.lineWidth = 1.6
        ci.stroke()
      case 1:  // 箭头（SVG）
        fillGlyph(Self.arrowGlyph, in: r.insetBy(dx: 7.2, dy: 8.2), white)
      case 2:  // 画笔（SVG）
        fillGlyph(Self.penGlyph, in: r.insetBy(dx: 6.7, dy: 6.7), white)
      case 3:  // 文字（暂未实现，淡显）
        let a = NSBezierPath()
        a.move(to: NSPoint(x: mid.x - 6, y: mid.y - 6.5))
        a.line(to: NSPoint(x: mid.x, y: mid.y + 6.5))
        a.line(to: NSPoint(x: mid.x + 6, y: mid.y - 6.5))
        a.move(to: NSPoint(x: mid.x - 3.1, y: mid.y - 1))
        a.line(to: NSPoint(x: mid.x + 3.1, y: mid.y - 1))
        NSColor(white: 0.5, alpha: 1).setStroke()
        a.lineWidth = 1.6
        a.lineCapStyle = .round
        a.lineJoinStyle = .round
        a.stroke()
      default:  // 马赛克：3×4 棋盘
        let cell: CGFloat = 4
        let ox = mid.x - 6, oy = mid.y - 6
        white.setFill()
        for row in 0..<3 {
          for col in 0..<3 where (row + col) % 2 == 0 {
            NSBezierPath(rect: NSRect(
              x: ox + CGFloat(col) * cell, y: oy + CGFloat(row) * cell,
              width: cell, height: cell)).fill()
          }
        }
      }
    }

    // 工具 / 动作 分隔线
    let psepX = (pb.tools[4].maxX + pb.actions[0].minX) / 2
    NSColor(white: 0.34, alpha: 1).setFill()
    NSRect(x: psepX, y: pb.bg.midY - 9, width: 1, height: 18).fill()

    // 动作：撤销 / ✕ / ⤓ / ✓
    let acts = pb.actions
    fillGlyph(Self.undoGlyph, in: acts[0].insetBy(dx: 5.8, dy: 5.8), white)

    let cx = acts[1].midX, cy = acts[1].midY
    let cross = NSBezierPath()
    cross.lineWidth = 2.4
    cross.lineCapStyle = .round
    cross.move(to: NSPoint(x: cx - 5, y: cy - 5))
    cross.line(to: NSPoint(x: cx + 5, y: cy + 5))
    cross.move(to: NSPoint(x: cx - 5, y: cy + 5))
    cross.line(to: NSPoint(x: cx + 5, y: cy - 5))
    red.setStroke()
    cross.stroke()

    let sx = acts[2].midX, sy = acts[2].midY
    let dl = NSBezierPath()
    dl.lineWidth = 2.2
    dl.lineCapStyle = .round
    dl.lineJoinStyle = .round
    dl.move(to: NSPoint(x: sx, y: sy + 7))
    dl.line(to: NSPoint(x: sx, y: sy - 3))
    dl.move(to: NSPoint(x: sx - 4, y: sy + 1))
    dl.line(to: NSPoint(x: sx, y: sy - 3))
    dl.line(to: NSPoint(x: sx + 4, y: sy + 1))
    dl.move(to: NSPoint(x: sx - 6.5, y: sy - 7))
    dl.line(to: NSPoint(x: sx + 6.5, y: sy - 7))
    white.setStroke()
    dl.stroke()

    let gx = acts[3].midX, gy = acts[3].midY
    let tick = NSBezierPath()
    tick.lineWidth = 2.6
    tick.lineCapStyle = .round
    tick.lineJoinStyle = .round
    tick.move(to: NSPoint(x: gx - 6, y: gy))
    tick.line(to: NSPoint(x: gx - 1.5, y: gy - 5))
    tick.line(to: NSPoint(x: gx + 6.5, y: gy + 5))
    green.setStroke()
    tick.stroke()

    // 二级
    if let sb = secondaryBar() {
      NSColor(white: 0.16, alpha: 0.95).setFill()
      NSBezierPath(roundedRect: sb.bg, xRadius: 8, yRadius: 8).fill()

      if primary == .shape {
        for (i, r) in sb.items.prefix(3).enumerated() {
          if shapeKind == [ShotTool.rect, .ellipse, .line][i] {
            NSColor(white: 0.32, alpha: 1).setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
          }
          let mx = r.midX, my = r.midY
          switch i {
          case 0:
            iconStroke(NSBezierPath(roundedRect: NSRect(
              x: mx - 6.5, y: my - 6.5, width: 13, height: 13), xRadius: 2.5, yRadius: 2.5))
          case 1:
            iconStroke(NSBezierPath(ovalIn: NSRect(
              x: mx - 6.5, y: my - 6.5, width: 13, height: 13)))
          default:
            let ln = NSBezierPath()
            ln.move(to: NSPoint(x: mx - 6.5, y: my - 6.5))
            ln.line(to: NSPoint(x: mx + 6.5, y: my + 6.5))
            iconStroke(ln)
          }
        }
        let sepX = (sb.items[2].maxX + sb.items[3].minX) / 2
        NSColor(white: 0.34, alpha: 1).setFill()
        NSRect(x: sepX, y: sb.bg.midY - 9, width: 1, height: 18).fill()
      }

      // 外框 / 填充 / 粗细
      if primary == .shape {
        let outline = sb.items[3], slider = sb.items[4], fill = sb.items[5]
        let widthOn = !shapeFilled
        drawStyleToggle(outline, filled: false, on: !shapeFilled)
        drawSlider(slider, enabled: widthOn)
        drawWidthValue(sb.value, enabled: widthOn)
        drawStyleToggle(fill, filled: true, on: shapeFilled)
      } else if primary == .mosaic {
        let segTitles = ["马赛克", "模糊", "涂抹", "框选"]
        for i in 0..<4 {
          let r = sb.items[i]
          let on: Bool
          switch i {
          case 0: on = !mosaicBlur
          case 1: on = mosaicBlur
          case 2: on = mosaicBrushMode
          default: on = !mosaicBrushMode
          }
          if on {
            NSColor(white: 0.32, alpha: 1).setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
          }
          let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(white: on ? 0.98 : 0.6, alpha: 1),
          ]
          let ts = (segTitles[i] as NSString).size(withAttributes: attrs)
          (segTitles[i] as NSString).draw(
            at: NSPoint(x: r.midX - ts.width / 2, y: r.midY - ts.height / 2),
            withAttributes: attrs)
        }
        let sepX = (sb.items[1].maxX + sb.items[2].minX) / 2
        NSColor(white: 0.34, alpha: 1).setFill()
        NSRect(x: sepX, y: sb.bg.midY - 9, width: 1, height: 18).fill()
        drawSlider(sb.items[4], ratio: (mosaicBlock - 1) / 9)
        drawWidthValue(sb.value, value: mosaicBlock)
      } else if let slider = sb.items.first {
        drawSlider(slider)
        drawWidthValue(sb.value)
      }

      // 颜色块 + ▾
      if primary != .mosaic {
      color.setFill()
      NSBezierPath(roundedRect: sb.swatch, xRadius: 4, yRadius: 4).fill()
      NSColor.white.withAlphaComponent(0.85).setStroke()
      let ring = NSBezierPath(roundedRect: sb.swatch, xRadius: 4, yRadius: 4)
      ring.lineWidth = 1
      ring.stroke()
      let ax = sb.arrow.midX, ay = sb.arrow.midY
      let chev = NSBezierPath()
      chev.lineWidth = 1.8
      chev.lineCapStyle = .round
      chev.move(to: NSPoint(x: ax - 4, y: ay + 2))
      chev.line(to: NSPoint(x: ax, y: ay - 2))
      chev.line(to: NSPoint(x: ax + 4, y: ay + 2))
      NSColor(white: 0.9, alpha: 1).setStroke()
      chev.stroke()

      }

      // 涂抹粗细三级菜单
      if showBrushMenu {
        let br = brushMenuRect()
        NSColor(white: 0.14, alpha: 0.98).setFill()
        NSBezierPath(roundedRect: br, xRadius: 8, yRadius: 8).fill()
        let dots = brushDotRects()
        for (i, dr) in dots.enumerated() {
          let d: CGFloat = [5, 8, 11][i]
          let on = abs(brushSize - brushSizes[i]) < 0.5
          if on {
            NSColor(white: 0.32, alpha: 1).setFill()
            NSBezierPath(roundedRect: dr, xRadius: 5, yRadius: 5).fill()
          }
          NSColor(white: on ? 0.98 : 0.62, alpha: 1).setFill()
          NSBezierPath(ovalIn: NSRect(
            x: dr.midX - d / 2, y: dr.midY - d / 2, width: d, height: d)).fill()
        }
      }

      // 自定义取色
      if showCustom {
        let cr = customRect()
        NSColor(white: 0.14, alpha: 0.98).setFill()
        NSBezierPath(roundedRect: cr, xRadius: 8, yRadius: 8).fill()

        // 饱和度 / 明度
        let sv = customSV()
        NSColor(hue: hueValue / 360, saturation: 1, brightness: 1, alpha: 1).setFill()
        sv.fill()
        NSGradient(colors: [NSColor(white: 1, alpha: 1), NSColor(white: 1, alpha: 0)])?
          .draw(in: sv, angle: 0)
        NSGradient(colors: [NSColor(white: 0, alpha: 0), NSColor(white: 0, alpha: 1)])?
          .draw(in: sv, angle: 270)
        NSColor(white: 0, alpha: 0.35).setStroke()
        let svRing = NSBezierPath(roundedRect: sv, xRadius: 4, yRadius: 4)
        svRing.lineWidth = 1
        svRing.stroke()

        let kx = sv.minX + satValue * sv.width
        let ky = sv.minY + brightValue * sv.height
        let knob = NSRect(x: kx - 6, y: ky - 6, width: 12, height: 12)
        NSColor(white: 0, alpha: 0.4).setStroke()
        let kOuter = NSBezierPath(ovalIn: knob.insetBy(dx: -1.5, dy: -1.5))
        kOuter.lineWidth = 3
        kOuter.stroke()
        NSColor.white.setStroke()
        let kInner = NSBezierPath(ovalIn: knob)
        kInner.lineWidth = 2
        kInner.stroke()

        // 色相条
        let hb = customHue()
        let rainbow = (0...6).map {
          NSColor(hue: CGFloat($0) / 6, saturation: 1, brightness: 1, alpha: 1)
        }
        NSGradient(colors: rainbow)?.draw(in: NSBezierPath(roundedRect: hb, xRadius: 4, yRadius: 4), angle: 0)
        let hx = hb.minX + (hueValue / 360) * hb.width
        NSColor.white.setStroke()
        let hk = NSBezierPath(
          roundedRect: NSRect(x: hx - 2.5, y: hb.minY - 2, width: 5, height: hb.height + 4),
          xRadius: 2.5, yRadius: 2.5)
        hk.lineWidth = 2
        hk.stroke()

        // 预览 + 色值
        let chip = customChip()
        color.setFill()
        NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
        NSColor.white.withAlphaComponent(0.7).setStroke()
        let chipRing = NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4)
        chipRing.lineWidth = 1
        chipRing.stroke()
        let hexAttrs: [NSAttributedString.Key: Any] = [
          .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
          .foregroundColor: NSColor(white: 0.85, alpha: 1),
        ]
        let hex = hexString() as NSString
        let hs = hex.size(withAttributes: hexAttrs)
        hex.draw(at: NSPoint(x: chip.maxX + 8, y: chip.midY - hs.height / 2), withAttributes: hexAttrs)
      }

      // 颜色弹层
      if showPalette {
        let pr = paletteRect()
        NSColor(white: 0.14, alpha: 0.98).setFill()
        NSBezierPath(roundedRect: pr, xRadius: 8, yRadius: 8).fill()
        let cells = paletteCells()
        for (i, r) in cells.enumerated() {
          if i < presets.count {
            presets[i].setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            if presets[i] == color {
              NSColor.white.setStroke()
              let ring = NSBezierPath(roundedRect: r.insetBy(dx: -2, dy: -2), xRadius: 5, yRadius: 5)
              ring.lineWidth = 1.5
              ring.stroke()
            }
          } else {
            let rainbow = (0...6).map {
              NSColor(hue: CGFloat($0) / 6, saturation: 0.9, brightness: 1, alpha: 1)
            }
            NSGradient(colors: rainbow)?.draw(
              in: NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4), angle: 0)
            NSColor.white.withAlphaComponent(showCustom ? 0.95 : 0.45).setStroke()
            let ring = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            ring.lineWidth = showCustom ? 1.5 : 1
            ring.stroke()
          }
        }
      }
    }
  }

  // MARK: 图标绘制

  private func iconStroke(_ p: NSBezierPath, _ color: NSColor = NSColor(white: 0.94, alpha: 1)) {
    p.lineWidth = 1.6
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    color.setStroke()
    p.stroke()
  }

  private func drawStyleToggle(_ r: NSRect, filled: Bool, on: Bool) {
    if on {
      NSColor(white: 0.32, alpha: 1).setFill()
      NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
    }
    let icon = NSRect(x: r.midX - 5, y: r.midY - 5, width: 10, height: 10)
    let path = NSBezierPath(roundedRect: icon, xRadius: 2, yRadius: 2)
    let c = NSColor(white: on ? 0.95 : 0.5, alpha: 1)
    if filled {
      c.setFill()
      path.fill()
    } else {
      path.lineWidth = 1.5
      c.setStroke()
      path.stroke()
    }
  }

  private func drawWidthValue(_ r: NSRect, enabled: Bool = true, value: CGFloat? = nil) {
    let v = ((value ?? lineWidth) * 10).rounded() / 10
    let text = (v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)) as NSString
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
      .foregroundColor: NSColor(white: enabled ? 0.95 : 0.4, alpha: 1),
    ]
    let s = text.size(withAttributes: attrs)
    text.draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2), withAttributes: attrs)
  }

  private func drawSlider(_ r: NSRect, enabled: Bool = true, ratio: CGFloat? = nil) {
    let track = NSRect(x: r.minX, y: r.midY - 1, width: r.width, height: 2)
    NSColor(white: enabled ? 0.45 : 0.26, alpha: 1).setFill()
    NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
    let t = max(0, min(1, ratio ?? (lineWidth - 1) / 11))
    let kx = r.minX + r.width * t
    NSColor(white: enabled ? 0.95 : 0.38, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: kx - 5, y: r.midY - 5, width: 10, height: 10)).fill()
  }
}
