// Code-drawn application icon and synthetic QA fixtures. No user photos used.
import AppKit
import Foundation

func bitmap(_ size: Int, draw: (CGContext) -> Void) -> NSBitmapImageRep {
  let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size,
    pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  let context = NSGraphicsContext(bitmapImageRep: image)!
  NSGraphicsContext.current = context
  context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
  draw(context.cgContext)
  NSGraphicsContext.restoreGraphicsState()
  return image
}

func icon(_ context: CGContext) {
  NSColor(calibratedRed: 0.13, green: 0.17, blue: 0.19, alpha: 1).setFill()
  NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 200, yRadius: 200).fill()
  NSColor.white.setStroke()
  for (x, y, sx, sy) in [(285.0,285.0,1.0,1.0),(739.0,285.0,-1.0,1.0),
    (285.0,739.0,1.0,-1.0),(739.0,739.0,-1.0,-1.0)] {
    let path = NSBezierPath()
    path.move(to: NSPoint(x:x, y:y+100*sy)); path.line(to: NSPoint(x:x,y:y))
    path.line(to: NSPoint(x:x+100*sx,y:y)); path.lineWidth=30
    path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
  }
  NSColor(calibratedRed: 0.47, green: 0.77, blue: 0.62, alpha: 1).setFill()
  let center = NSBezierPath()
  center.move(to: NSPoint(x: 512, y: 660)); center.line(to: NSPoint(x: 660, y: 512))
  center.line(to: NSPoint(x: 512, y: 364)); center.line(to: NSPoint(x: 364, y: 512))
  center.close(); center.fill()
  NSColor(calibratedRed: 0.13, green: 0.17, blue: 0.19, alpha: 1).setFill()
  NSBezierPath(ovalIn: NSRect(x: 470, y: 470, width: 84, height: 84)).fill()
}

if CommandLine.arguments.dropFirst().first == "icon" {
  let directory = URL(fileURLWithPath: "macos/Runner/Assets.xcassets/AppIcon.appiconset")
  for size in [16, 32, 64, 128, 256, 512, 1024] {
    let data = bitmap(size, draw: icon).representation(using: .png, properties: [:])!
    try data.write(to: directory.appendingPathComponent("app_icon_\(size).png"))
  }
  // ICO permits PNG payloads. Build its directory and payloads without extra tools.
  let sizes = [16, 32, 48, 64, 128, 256]
  let images = sizes.map { bitmap($0, draw: icon).representation(using: .png, properties: [:])! }
  var ico = Data([0, 0, 1, 0, UInt8(sizes.count), 0])
  func little(_ value: UInt32, _ count: Int) -> [UInt8] {
    (0..<count).map { UInt8((value >> ($0 * 8)) & 255) }
  }
  var offset = 6 + sizes.count * 16
  for (index, data) in images.enumerated() {
    let side = sizes[index] == 256 ? 0 : UInt8(sizes[index])
    ico.append(contentsOf: [side, side, 0, 0, 1, 0, 32, 0])
    ico.append(contentsOf: little(UInt32(data.count), 4))
    ico.append(contentsOf: little(UInt32(offset), 4)); offset += data.count
  }
  images.forEach { ico.append($0) }
  let output = URL(fileURLWithPath: "windows/runner/resources/app_icon.ico")
  try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
  try ico.write(to: output)
  print("Generated macOS and Windows icons")
} else {
  let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/raw_picker_demo")
  let jpg = root.appendingPathComponent("已选JPG"), raw = root.appendingPathComponent("全部RAW")
  for path in [jpg, raw, root.appendingPathComponent("导出")] {
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
  }
  for index in 1...7 {
    let image = bitmap(800) { _ in
      let colors = index % 2 == 0 ? [NSColor(calibratedRed:0.72,green:0.80,blue:0.79,alpha:1),
        NSColor(calibratedRed:0.27,green:0.45,blue:0.45,alpha:1)] :
        [NSColor(calibratedRed:0.92,green:0.76,blue:0.53,alpha:1),
        NSColor(calibratedRed:0.52,green:0.45,blue:0.39,alpha:1)]
      NSGradient(starting: colors[0], ending: colors[1])!.draw(in: NSRect(x:0,y:0,width:1024,height:1024), angle:90)
      NSColor(calibratedWhite: 1, alpha:0.65).setFill()
      NSBezierPath(ovalIn:NSRect(x:650-index*30,y:640,width:110,height:110)).fill()
      for layer in 0...3 {
        NSColor(calibratedRed:0.12+Double(layer)*0.04,green:0.23+Double(layer)*0.035,blue:0.24+Double(layer)*0.025,alpha:1).setFill()
        let path=NSBezierPath(); path.move(to:NSPoint(x:0,y:0)); path.line(to:NSPoint(x:0,y:180+layer*90))
        for step in 0...8 {
          let height=170+layer*65+Int(sin(Double(step+index+layer)*1.6)*90)
          path.line(to:NSPoint(x:step*150,y:height))
        }
        path.line(to:NSPoint(x:1024,y:0)); path.close(); path.fill()
      }
      let label = "测试示例 / \(index)" as NSString
      label.draw(at: NSPoint(x:60,y:65), withAttributes:[.font:NSFont.systemFont(ofSize:24),.foregroundColor:NSColor.white.withAlphaComponent(0.7)])
    }
    let name=String(format:"DSC_%04d",index)
    try image.representation(using:.jpeg,properties:[.compressionFactor:0.85])!.write(to:jpg.appendingPathComponent("\(name).JPG"))
    if index == 5 { continue }
    let folder = raw.appendingPathComponent(index == 6 ? "第二天" : "第一天")
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    try Data(repeating: UInt8(index), count: 512*1024).write(to:folder.appendingPathComponent("\(name).NEF"))
    if index == 6 {
      let other=raw.appendingPathComponent("第一天")
      try Data(repeating: 99, count: 256*1024).write(to:other.appendingPathComponent("\(name).NEF"))
    }
  }
  try "这些 JPG 为程序绘制的测试图；NEF 为占位数据，仅用于验证匹配和复制，不能用于修图。\n".write(to:root.appendingPathComponent("测试素材说明.txt"), atomically:true, encoding:.utf8)
  print(root.path)
}
