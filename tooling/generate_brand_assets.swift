import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("assets/brand/moduly_mark_source.png")

guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("소스 이미지를 읽을 수 없습니다: \(sourceURL.path)")
}

let cream = CGColor(red: 1.0, green: 0.969, blue: 0.91, alpha: 1.0)

func render(
    to outputURL: URL,
    width: Int,
    height: Int,
    background: CGColor?,
    inset: CGFloat = 0.0,
    markScale: CGFloat = 1.0
) throws {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "BrandAssets", code: 1)
    }
    let canvas = CGRect(x: 0, y: 0, width: width, height: height)
    if let background {
        context.setFillColor(background)
        context.fill(canvas)
    }

    let available = min(CGFloat(width), CGFloat(height)) * (1.0 - inset * 2.0)
    let side = available * markScale
    let x = (CGFloat(width) - side) / 2.0
    let y = (CGFloat(height) - side) / 2.0
    context.interpolationQuality = .high
    context.draw(sourceImage, in: CGRect(x: x, y: y, width: side, height: side))

    guard let output = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              outputURL as CFURL,
              UTType.png.identifier as CFString,
              1,
              nil
          ) else {
        throw NSError(domain: "BrandAssets", code: 2)
    }
    CGImageDestinationAddImage(destination, output, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "BrandAssets", code: 3)
    }
}

func ensureDirectory(_ url: URL) throws {
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
}

func renderNamed(_ relativePath: String, width: Int, height: Int, background: CGColor?, inset: CGFloat = 0.0, markScale: CGFloat = 1.0) throws {
    let outputURL = root.appendingPathComponent(relativePath)
    try ensureDirectory(outputURL.deletingLastPathComponent())
    try render(to: outputURL, width: width, height: height, background: background, inset: inset, markScale: markScale)
}

// 디자이너와 마케팅/웹 대체용으로 사용하는 기준 불투명 원본이다.
try renderNamed("assets/brand/moduly_mark_1024.png", width: 1024, height: 1024, background: cream, inset: 0.0)

// Android 레거시 밀도별 리소스다.
for (directory, size) in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)] {
    try renderNamed("android/app/src/main/res/mipmap-\(directory)/ic_launcher.png", width: size, height: size, background: cream, inset: 0.0)
    try renderNamed("android/app/src/main/res/mipmap-\(directory)/ic_launcher_round.png", width: size, height: size, background: cream, inset: 0.0)
}

// Android 적응형 아이콘에서 사용하는 투명 전경 레이어다.
try renderNamed("android/app/src/main/res/drawable-nodpi/moduly_mark_foreground.png", width: 432, height: 432, background: nil, inset: 0.0)

// 마스크 가능한 아이콘을 위해 안전 여백을 더한 웹/PWA 아이콘이다.
try renderNamed("web/icons/Icon-192.png", width: 192, height: 192, background: cream, inset: 0.0)
try renderNamed("web/icons/Icon-512.png", width: 512, height: 512, background: cream, inset: 0.0)
try renderNamed("web/icons/Icon-maskable-192.png", width: 192, height: 192, background: cream, inset: 0.12)
try renderNamed("web/icons/Icon-maskable-512.png", width: 512, height: 512, background: cream, inset: 0.12)
try renderNamed("web/favicon.png", width: 64, height: 64, background: cream, inset: 0.0)

// iOS AppIcon 카탈로그 크기다.
let iosIcons: [(String, Int)] = [
    ("Icon-App-20x20@1x.png", 20), ("Icon-App-20x20@2x.png", 40), ("Icon-App-20x20@3x.png", 60),
    ("Icon-App-29x29@1x.png", 29), ("Icon-App-29x29@2x.png", 58), ("Icon-App-29x29@3x.png", 87),
    ("Icon-App-40x40@1x.png", 40), ("Icon-App-40x40@2x.png", 80), ("Icon-App-40x40@3x.png", 120),
    ("Icon-App-60x60@2x.png", 120), ("Icon-App-60x60@3x.png", 180),
    ("Icon-App-76x76@1x.png", 76), ("Icon-App-76x76@2x.png", 152),
    ("Icon-App-83.5x83.5@2x.png", 167), ("Icon-App-1024x1024@1x.png", 1024)
]
for (name, size) in iosIcons {
    try renderNamed("ios/Runner/Assets.xcassets/AppIcon.appiconset/\(name)", width: size, height: size, background: cream, inset: 0.0)
}

// iOS 시작 이미지는 기존 범용 세로형 카탈로그를 유지한다.
try renderNamed("ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage.png", width: 320, height: 480, background: cream, inset: 0.0, markScale: 0.50)
try renderNamed("ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@2x.png", width: 640, height: 960, background: cream, inset: 0.0, markScale: 0.50)
try renderNamed("ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@3x.png", width: 960, height: 1440, background: cream, inset: 0.0, markScale: 0.50)

// 크림색 레이어 중앙에 배치하는 Android 시작 배경 비트맵이다.
try renderNamed("android/app/src/main/res/drawable-nodpi/moduly_splash.png", width: 512, height: 512, background: cream, inset: 0.0, markScale: 0.50)

print("다음 소스에서 Moduly 브랜드 에셋을 생성했습니다: " + sourceURL.path)
