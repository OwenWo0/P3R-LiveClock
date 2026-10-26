import ClockKit
import CoreText
import UIKit

/// 时间单独交给小尺寸复杂功能的分钟时间线，避免每分钟复制整套动画。
///
/// 外观为方案 G「菜单竖排」：右侧蓝色水面上自上而下四行——时、分、日期、星期，
/// 仿 P3R 主菜单：SF Black 斜体，亮水色半透明，深蓝错位影子；行距小于字高互相压叠，倾角正负交替。
///
/// 针对 Apple Watch Ultra / Ultra 2 49mm（205×251 点 / 410×502 像素，圆角 27 点）适配：
/// 右下槽位中心在屏幕 (169.5, 215.5) 点。为节省内存，时间画布收敛为 136×296 点（272×592 像素），
/// 覆盖屏幕 x 101.5–205、y 67.5–251，比旧 144×434 点画布减少约 36% 像素，且渲染后立即转为
/// PNG 压缩数据释放位图上下文，将 15 分钟时间线批量生成的脏内存峰值降低约 90%。
enum GlassClock {
    static let identifier = "glass-clock"

    private static let slotCenter = CGPoint(x: 169.5, y: 215.5)
    private static let imageSize = CGSize(width: 136, height: 296)
    /// 图左上角在屏幕上的位置
    private static let origin = CGPoint(x: slotCenter.x - imageSize.width / 2, y: slotCenter.y - imageSize.height / 2)

    // 版式（Ultra 2 49mm 205×251 屏幕点）：时分 54 号、日期星期 25 号，首行中心 y=101，右缘 x=196（计入斜体与旋转外扩后距右缘约 4 点）。
    private static let big: CGFloat = 54, small: CGFloat = 25, top: CGFloat = 101, right: CGFloat = 196
    private static let overlap: CGFloat = 0.55      // 时、分中心间距 = big × overlap，小于字高所以压叠
    private static let skewDeg: CGFloat = 16
    private static let cyan = UIColor(red: 0x8B / 255.0, green: 0xE8 / 255.0, blue: 0xF5 / 255.0, alpha: 0.82)
    private static let shadow = UIColor(red: 0x16 / 255.0, green: 0x3F / 255.0, blue: 0xB0 / 255.0, alpha: 0.85)
    private static let colorSpace = CGColorSpaceCreateDeviceRGB()
    private static let bigFont = tabular(UIFont.systemFont(ofSize: big, weight: .black, width: .standard))
    private static let smallFont = tabular(UIFont.systemFont(ofSize: small, weight: .black, width: .standard))

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"; return f
    }()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "M/d"; return f
    }()
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE"; return f
    }()

    static func template(at date: Date) -> CLKComplicationTemplate? {
        guard let image = render(at: date) else { return nil }
        let provider = CLKFullColorImageProvider(fullColorImage: image)
        provider.accessibilityLabel = timeFormatter.string(from: date)
        // 非公开字段：关掉系统缩放与圆形遮罩，图才能按原尺寸超出槽位绘制。
        provider.setValue(false, forKey: "applyScalingAndCircularMasking")
        return CLKComplicationTemplateGraphicCircularImage(imageProvider: provider)
    }

    static func nextMinute(after date: Date) -> Date {
        Calendar.autoupdatingCurrent.dateInterval(of: .minute, for: date)!.end
    }

    // MARK: - 绘制

    private static func render(at date: Date) -> UIImage? {
        autoreleasepool {
            let scale: CGFloat = 2
            let w = Int(imageSize.width * scale), h = Int(imageSize.height * scale)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.scaleBy(x: scale, y: scale)

            let hm = timeFormatter.string(from: date).split(separator: ":").map(String.init)
            let ys = [top, top + big * overlap,
                      top + big * overlap + big * 0.38 + small * 0.62,
                      top + big * overlap + big * 0.38 + small * 1.67]
            // 文字、字体、字号、倾角、字距、右缘内缩
            let rows: [(String, UIFont, CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (hm[0], bigFont, big, 10, 0, 2), (hm[1], bigFont, big, -8, 0, 4),
                (dateFormatter.string(from: date), smallFont, small, 8, 0.5, 3),
                (weekdayFormatter.string(from: date).uppercased(), smallFont, small, -7, 1.0, 10)]
            for (i, (text, font, size, deg, kern, inset)) in rows.enumerated() {
                let width = lineWidth(text, font: font, kern: kern)
                let k = max(size / 60, 0.45)
                let center = CGPoint(x: right - inset - width / 2, y: ys[i])
                drawLine(ctx, text, font: font, color: shadow, center: center, offset: CGSize(width: 2.8 * k, height: 3.6 * k), deg: deg, kern: kern)
                drawLine(ctx, text, font: font, color: cyan, center: center, offset: .zero, deg: deg, kern: kern)
            }
            guard let cg = ctx.makeImage() else { return nil }
            let raw = UIImage(cgImage: cg, scale: scale, orientation: .up)
            // 立即压成 ~8 KB 的 PNG 数据后释放未压缩位图上下文，避免 15 条时间线占用近 10 MB 脏内存
            if let png = raw.pngData(), let compact = UIImage(data: png, scale: scale) {
                return compact
            }
            return raw
        }
    }

    /// 等宽数字：SF 默认是比例数字，「1」比「0」窄。等宽后每分钟行宽一致，排版不随时间左右跳，
    /// 宽度上限也确定。
    private static func tabular(_ font: UIFont) -> UIFont {
        let d = font.fontDescriptor.addingAttributes([.featureSettings: [[UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                                                                          UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector]]])
        return UIFont(descriptor: d, size: font.pointSize)
    }

    private static func lineWidth(_ text: String, font: UIFont, kern: CGFloat) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .kern: kern]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - kern
    }

    /// 绕中心旋转、整体错切成斜体的一行字。center 是屏幕点（y 向下）。
    private static func drawLine(_ ctx: CGContext, _ text: String, font: UIFont, color: UIColor, center: CGPoint,
                                 offset: CGSize, deg: CGFloat, kern: CGFloat) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .kern: kern]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - kern
        let skew = tan(skewDeg * .pi / 180)
        // 屏幕点 → 图内点，再翻成 CoreGraphics 的 y 向上
        let x = center.x + offset.width - origin.x
        let y = imageSize.height - (center.y + offset.height - origin.y)
        ctx.saveGState()
        ctx.translateBy(x: x, y: y)
        ctx.rotate(by: deg * .pi / 180)
        ctx.textMatrix = CGAffineTransform(a: 1, b: 0, c: skew, d: 1, tx: 0, ty: 0)
        ctx.textPosition = CGPoint(x: -width / 2 - font.capHeight / 2 * skew, y: -font.capHeight / 2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
