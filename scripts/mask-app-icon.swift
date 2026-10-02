import CoreGraphics
import Foundation
import ImageIO

guard CommandLine.arguments.count == 3 else {
    fputs("usage: mask-app-icon.swift <source.png> <output.png>\n", stderr)
    exit(2)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    fputs("Unable to read source image.\n", stderr)
    exit(1)
}

let size = min(image.width, image.height)
let canvas = CGRect(x: 0, y: 0, width: size, height: size)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

guard let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: size * 4,
    space: colorSpace,
    bitmapInfo: bitmapInfo
) else {
    fputs("Unable to create image context.\n", stderr)
    exit(1)
}

context.clear(canvas)
let margin = CGFloat(size) * 0.045
let tile = canvas.insetBy(dx: margin, dy: margin)
let cornerRadius = CGFloat(size) * 0.19
let mask = CGPath(
    roundedRect: tile,
    cornerWidth: cornerRadius,
    cornerHeight: cornerRadius,
    transform: nil
)

context.saveGState()
context.addPath(mask)
context.clip()
context.interpolationQuality = .high
context.draw(image, in: canvas)
context.restoreGState()

guard let outputImage = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        "public.png" as CFString,
        1,
        nil
      ) else {
    fputs("Unable to create output image.\n", stderr)
    exit(1)
}

CGImageDestinationAddImage(destination, outputImage, nil)

guard CGImageDestinationFinalize(destination) else {
    fputs("Unable to write output image.\n", stderr)
    exit(1)
}
