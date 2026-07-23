// swift-format-ignore-file
// Uniform literal runs (Codable field blocks, preset tables): periodic
// self-similar content, not duplication. Must stay silent.
struct Palette: Codable {
    let primaryRed: Int
    let primaryGreen: Int
    let primaryBlue: Int
    let secondaryRed: Int
    let secondaryGreen: Int
    let secondaryBlue: Int
    let accentRed: Int
    let accentGreen: Int
    let accentBlue: Int
    let borderRed: Int
    let borderGreen: Int
    let borderBlue: Int
}

let presets: [[Int]] = [
    [255, 0, 0, 128, 128, 128],
    [0, 255, 0, 64, 64, 64],
    [0, 0, 255, 32, 32, 32],
    [255, 255, 0, 16, 16, 16],
    [255, 0, 255, 8, 8, 8],
]
