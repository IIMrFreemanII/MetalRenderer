/// A generated texture's RGBA8 pixels, sRGB-encoded, rows from v = 0 (the plants', the scans' packed maps).
package struct GeneratedImage {
    package var width: Int
    package var height: Int
    package var pixels: [UInt8]

    package init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}
