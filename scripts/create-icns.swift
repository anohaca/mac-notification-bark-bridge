import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: create-icns.swift <iconset-directory> <output.icns>\n", stderr)
    exit(2)
}

let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

// PNG-backed representations cover Finder, Dock, and Retina sizes on macOS 13+.
let representations: [(type: String, file: String)] = [
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_16x16@2x.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
]

func bigEndianBytes(_ value: UInt32) -> [UInt8] {
    [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff),
    ]
}

var icon = Data([0x69, 0x63, 0x6e, 0x73, 0, 0, 0, 0])

for representation in representations {
    let imageURL = iconsetURL.appendingPathComponent(representation.file)
    let image = try Data(contentsOf: imageURL)
    guard let typeData = representation.type.data(using: .ascii) else {
        throw NSError(domain: "CreateICNSError", code: 1)
    }

    icon.append(typeData)
    icon.append(contentsOf: bigEndianBytes(UInt32(image.count + 8)))
    icon.append(image)
}

icon.replaceSubrange(4..<8, with: bigEndianBytes(UInt32(icon.count)))
try icon.write(to: outputURL, options: .atomic)
