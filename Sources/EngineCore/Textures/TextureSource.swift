import Foundation

/// An encoded image a material samples (decoded and uploaded by the renderer).
package struct TextureSource {
    package var data: Data
    var srgb: Bool                        // colour data (base colour, emissive) vs linear (normal, metallic-roughness)
    var name: String
    var modelPath: String                 // the glTF file (texture streaming caches per file)
    var cacheKey: String                  // unique within the file: image index + colour space
    /// Generated (`addGeneratedTexture`): `data` is this many RGBA8 pixels, not an encoded image.
    var raw: (width: Int, height: Int)? = nil
    /// ...or they are drawn by this when someone needs them (a texture the caches already hold never is).
    var pixels: (() -> Data)? = nil

    /// A generated texture's pixels, drawn now if they are behind `pixels`.
    var rawPixels: Data { pixels?() ?? data }
    /// Which image it is, for telling that two scenes' textures are the same ones (an open world's next scene
    /// keeps the textures it is drawn with): its file and its key in it, which for a generated one says what
    /// it is made from.
    package var identity: String { "\(modelPath)|\(cacheKey)|\(name)|\(srgb)|\(raw?.width ?? 0)x\(raw?.height ?? 0)|\(data.count)" }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(data: Data, srgb: Bool, name: String, modelPath: String, cacheKey: String, raw: (width: Int, height: Int)? = nil, pixels: (() -> Data)? = nil) {
        self.data = data
        self.srgb = srgb
        self.name = name
        self.modelPath = modelPath
        self.cacheKey = cacheKey
        self.raw = raw
        self.pixels = pixels
    }
}
