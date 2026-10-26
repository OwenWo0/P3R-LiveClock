import SwiftUI
import ClockKit
import UIKit
import WatchKit
import os

/// 前台提供设置说明与交接诊断；动画和时间由系统表盘中的复杂功能显示。
@main
struct ComplicationResearch: App {
    @WKApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup { StatusView() }
    }
}

/// 首页：设置说明 + 交接状态 + 内存模式切换 + 最近 40 条诊断日志。真机卡住时截图这一页即可定位卡在哪一步。
struct StatusView: View {
    @State private var events: [String] = []
    @State private var pending: Date?
    @State private var last: Date?
    @State private var lowMemory = HandoffHealth.lowMemoryMode

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("P3R 原生动态表盘").font(.headline)
                Text("Ultra 2 49mm (410×502) · 版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")（\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")）").font(.footnote).foregroundStyle(.secondary)
                Text("编辑系统「模块化」表盘，颜色选「多色」。中央：P3R 动画研究；右下：P3R 玻璃时间；其他关闭。").font(.footnote)
                Divider()
                Text(pending != nil ? "交接：未完成（自 \(Self.short(pending!))）" : "交接：正常").font(.footnote.bold())
                    .foregroundStyle(pending != nil ? .orange : .green)
                Text("上次交出动画：\(last.map(Self.short) ?? "无")").font(.footnote)
                Text("帧率模式：\(lowMemory ? "省内存 40 帧 (6fps · ~35MB)" : "高清 80 帧 (12fps · ~70MB)")").font(.footnote)
                Button(lowMemory ? "切换为高清 80 帧" : "切换为省内存 40 帧") {
                    lowMemory.toggle()
                    HandoffHealth.lowMemoryMode = lowMemory
                    HandoffHealth.record("切换为\(lowMemory ? "省内存 40 帧" : "高清 80 帧")模式")
                    HandoffHealth.reloadAll()
                    refresh()
                }
                Button("手动修复（重载表盘数据）") { HandoffHealth.record("手动修复"); HandoffHealth.reloadAll(); refresh() }
                Divider()
                Text("最近事件").font(.footnote.bold())
                ForEach(events, id: \.self) { Text($0).font(.system(size: 10, design: .monospaced)) }
            }.padding(.horizontal, 4)
        }
        .task {
            // 打开应用本身就是一次重载：这正是用户以前手动「点进应用再退出」恢复动画的原因
            HandoffHealth.record("打开素材应用，重载表盘数据")
            HandoffHealth.reloadAll()
            HandoffHealth.scheduleRefresh()
            refresh()
        }
    }

    private func refresh() {
        events = HandoffHealth.events
        pending = HandoffHealth.pendingSince
        last = HandoffHealth.lastDelivered
        lowMemory = HandoffHealth.lowMemoryMode
    }

    private static func short(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "M/d HH:mm:ss"; return f.string(from: d)
    }
}

@objc(LCAnimatedComplication)
final class AnimatedComplication: NSObject, CLKComplicationDataSource {
    private let logger = Logger(subsystem: "p3r.liveclock", category: "复杂功能")
    // 先显示静帧，让宿主图片视图建立 2 倍像素密度，再沿用该视图播放动画。
    private var animationReadyDate = Date().addingTimeInterval(3)
    private static let frameManifest: [String: Any]? = {
        guard let url = Bundle.main.url(forResource: "frames", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }()
    /// 使用内存映射读取 PNG 原始数据构造 UIImage，避免解码到本进程脏内存，并保留 PNG 底层数据供 XPC 直接编码。
    private static func frame(_ index: Int) -> UIImage? {
        autoreleasepool {
            guard let url = Bundle.main.url(forResource: String(format: "p3r-%04d", index), withExtension: "png"),
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            let scale = (frameManifest?["scale"] as? Double) ?? 2
            return UIImage(data: data, scale: scale)
        }
    }
    private static func loadInitialImage() -> UIImage? {
        autoreleasepool {
            guard let url = Bundle.main.url(forResource: "poster-retina", withExtension: "png"),
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let img = UIImage(data: data, scale: 2) else { return frame(0) }
            return img
        }
    }
    /// 按需构建动画帧并在交接后立即释放，不在常驻静态变量里长期持有 80 帧对象。
    private static func buildAnimation() -> UIImage? {
        autoreleasepool {
            guard let json = frameManifest,
                  let count = json["frameCount"] as? Int,
                  let duration = json["duration"] as? Double else { return nil }
            let strideStep = HandoffHealth.lowMemoryMode ? 2 : 1
            let indices = Array(stride(from: 0, to: count, by: strideStep))
            let frames = indices.compactMap { frame($0) }
            guard frames.count == indices.count else { return nil }
            return UIImage.animatedImage(with: frames, duration: duration)
        }
    }

    private func template(_ family: CLKComplicationFamily, initial: Bool = false) -> CLKComplicationTemplate? {
        let selectedImage = initial ? Self.loadInitialImage() : Self.buildAnimation()
        guard let image = selectedImage else { return nil }
        let provider = CLKFullColorImageProvider(fullColorImage: image)
        // 非公开字段：仅用于个人研究，禁止默认缩放压平动画帧。
        provider.setValue(false, forKey: "applyScalingAndCircularMasking")
        // 息屏时沿用显示视图；另换模板会使唤醒后的动画丢失像素密度。
        provider.setValue(true, forKey: "prefersFilterOverTransition")
        logger.notice("生成动画模板，family=\(family.rawValue)，帧数=\(image.images?.count ?? 0)，初始化=\(initial)")
        switch family {
        case .graphicRectangular:
            return CLKComplicationTemplateGraphicRectangularFullImage(imageProvider: provider)
        default:
            return nil
        }
    }

    func getComplicationDescriptors(handler: @escaping ([CLKComplicationDescriptor]) -> Void) {
        logger.notice("请求复杂功能描述")
        let descriptors = [CLKComplicationDescriptor(identifier: "frames", displayName: "P3R 动画研究", supportedFamilies: [.graphicRectangular]),
                           CLKComplicationDescriptor(identifier: GlassClock.identifier, displayName: "P3R 玻璃时间", supportedFamilies: [.graphicCircular])]
        handler(descriptors)
    }

    func getCurrentTimelineEntry(for complication: CLKComplication, withHandler handler: @escaping (CLKComplicationTimelineEntry?) -> Void) {
        if complication.identifier == GlassClock.identifier {
            let date = Date()
            handler(GlassClock.template(at: date).map { CLKComplicationTimelineEntry(date: date, complicationTemplate: $0) })
            logger.notice("请求右下时间当前条目")
            return
        }
        HandoffHealth.requestStarted()
        let now = Date()
        animationReadyDate = now.addingTimeInterval(3)
        logger.notice("显示高清初始化静帧，三秒后切换动画")
        let entry = template(complication.family, initial: true).map {
            CLKComplicationTimelineEntry(date: now, complicationTemplate: $0)
        }
        handler(entry)
        if entry != nil { HandoffHealth.stillDelivered() } else { HandoffHealth.record("静帧模板生成失败") }
    }

    func getLocalizableSampleTemplate(for complication: CLKComplication, withHandler handler: @escaping (CLKComplicationTemplate?) -> Void) {
        if complication.identifier == GlassClock.identifier { handler(GlassClock.template(at: Date())); return }
        logger.notice("请求动画预览")
        handler(template(complication.family, initial: true))
    }

    func getAlwaysOnTemplate(for complication: CLKComplication, withHandler handler: @escaping (CLKComplicationTemplate?) -> Void) {
        // 让系统冻结当前画面；独立常亮模板会在唤醒时重建比例错误的动画视图。
        // 时间组件也沿用当前分钟条目，避免常亮专用模板固定住时间。
        handler(nil)
    }

    func getPrivacyBehavior(for complication: CLKComplication, withHandler handler: @escaping (CLKComplicationPrivacyBehavior) -> Void) {
        handler(.showOnLockScreen)
    }

    func getTimelineEndDate(for complication: CLKComplication, withHandler handler: @escaping (Date?) -> Void) {
        handler(Date().addingTimeInterval(24 * 3600))
    }

    func getTimelineAnimationBehavior(for complication: CLKComplication, withHandler handler: @escaping (CLKComplicationTimelineAnimationBehavior) -> Void) {
        handler(.never)
    }

    func getTimelineEntries(for complication: CLKComplication, after date: Date, limit: Int, withHandler handler: @escaping ([CLKComplicationTimelineEntry]?) -> Void) {
        guard limit > 0 else { handler(nil); return }
        if complication.identifier != GlassClock.identifier {
            // 调试：丢弃一次动画条目请求，在模拟器里人为制造「只要了静帧、没要到动画」的卡死，验证看门狗
            if HandoffHealth.consumeDropFuture() {
                HandoffHealth.record("调试：丢弃这一次动画条目请求")
                handler(nil)
                return
            }
            guard date < animationReadyDate else {
                handler(nil)
                return
            }
            let entry: CLKComplicationTimelineEntry? = autoreleasepool {
                guard let value = template(complication.family) else { return nil }
                return CLKComplicationTimelineEntry(date: animationReadyDate, complicationTemplate: value)
            }
            guard let entry else {
                handler(nil)
                return
            }
            logger.notice("提供高清动画未来条目")
            handler([entry])
            HandoffHealth.animationDelivered()
            return
        }
        let end = Date().addingTimeInterval(24 * 3600)
        var next = GlassClock.nextMinute(after: date)
        var entries: [CLKComplicationTimelineEntry] = []
        // 每张时间图渲染后已压为 ~8 KB 的 PNG 数据（272×592 像素），一次排 15 分钟。
        while entries.count < min(limit, 15), next <= end {
            autoreleasepool {
                if let template = GlassClock.template(at: next) {
                    entries.append(CLKComplicationTimelineEntry(date: next, complicationTemplate: template))
                }
            }
            next = GlassClock.nextMinute(after: next)
        }
        logger.notice("提供右下时间未来条目：\(entries.count)")
        handler(entries)
    }
}
