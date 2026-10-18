import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// PadBridge のアイコンを描画し、iPad と Mac のアセットカタログに書き出す: swift Scripts/AppIcon.swift <iPad の appiconset> <Mac の appiconset>
// 青い背景に、Mac (ノート) と、その手前に重なるマイクを表示した iPad を白で描く。SF Symbols はアイコンに使えないので形は自前で描く
let size = 1024
let space = CGColorSpace(name: CGColorSpace.displayP3)!
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// 左上を原点にして描画する
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: 1, y: -1)

let top = CGColor(colorSpace: space, components: [0.16, 0.42, 1.0, 1])!
let bottom = CGColor(colorSpace: space, components: [0.33, 0.20, 0.86, 1])!
let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
// 描画を中央に寄せたあとも、背景のグラデーションはキャンバスに対して同じ位置に塗る
var shift = CGPoint.zero
func fillBackground() {
    context.drawLinearGradient(gradient, start: CGPoint(x: -shift.x, y: -shift.y), end: CGPoint(x: -shift.x, y: CGFloat(size) - shift.y), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
let white = CGColor(colorSpace: space, components: [1, 1, 1, 1])!

fillBackground()
// 描画全体 (横 90〜880、縦 228〜860) を中央に寄せる
shift = CGPoint(x: 27, y: -32)
context.translateBy(x: shift.x, y: shift.y)

// Mac のディスプレイとスタンド
let screen = CGRect(x: 150, y: 250, width: 600, height: 400)
context.setStrokeColor(white)
context.setLineWidth(44)
context.addPath(CGPath(roundedRect: screen, cornerWidth: 40, cornerHeight: 40, transform: nil))
context.strokePath()
context.setFillColor(white)
context.addPath(CGPath(roundedRect: CGRect(x: 90, y: 680, width: 720, height: 56), cornerWidth: 28, cornerHeight: 28, transform: nil))
context.fillPath()

// iPad の周りを背景色で抜き、重なりを見分けやすくする
let pad = CGRect(x: 560, y: 420, width: 320, height: 440)
context.saveGState()
context.addPath(CGPath(roundedRect: pad.insetBy(dx: -30, dy: -30), cornerWidth: 74, cornerHeight: 74, transform: nil))
context.clip()
fillBackground()
context.restoreGState()

context.setFillColor(white)
context.addPath(CGPath(roundedRect: pad, cornerWidth: 48, cornerHeight: 48, transform: nil))
context.fillPath()
let padScreen = pad.insetBy(dx: 30, dy: 30)
context.saveGState()
context.addPath(CGPath(roundedRect: padScreen, cornerWidth: 22, cornerHeight: 22, transform: nil))
context.clip()
fillBackground()
context.restoreGState()

// iPad の画面上のマイク
let micCenterX = padScreen.midX
let capsule = CGRect(x: micCenterX - 40, y: padScreen.minY + 90, width: 80, height: 140)
context.setFillColor(white)
context.addPath(CGPath(roundedRect: capsule, cornerWidth: 40, cornerHeight: 40, transform: nil))
context.fillPath()
context.setStrokeColor(white)
context.setLineWidth(22)
context.setLineCap(.round)
let arcCenter = CGPoint(x: micCenterX, y: capsule.maxY - 40)
context.addArc(center: arcCenter, radius: 72, startAngle: 0, endAngle: .pi, clockwise: false)
context.strokePath()
context.move(to: CGPoint(x: micCenterX, y: arcCenter.y + 72))
context.addLine(to: CGPoint(x: micCenterX, y: arcCenter.y + 118))
context.strokePath()
context.move(to: CGPoint(x: micCenterX - 48, y: arcCenter.y + 118))
context.addLine(to: CGPoint(x: micCenterX + 48, y: arcCenter.y + 118))
context.strokePath()

let image = context.makeImage()!
func write(_ image: CGImage, to path: String) {
    let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}
let padIconSet = CommandLine.arguments[1]
let macIconSet = CommandLine.arguments[2]
write(image, to: "\(padIconSet)/AppIcon.png")
func scaled(_ pixels: Int) -> CGImage {
    let small = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    small.interpolationQuality = .high
    small.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    return small.makeImage()!
}
for points in [16, 32, 128, 256, 512] {
    write(scaled(points), to: "\(macIconSet)/icon_\(points)x\(points).png")
    write(scaled(points * 2), to: "\(macIconSet)/icon_\(points)x\(points)@2x.png")
}
