/// What can fail making the renderer's GPU objects.
package enum RendererError: Error, CustomStringConvertible {
    case missingFunction(String)
    case resourceCreation(String)
    case unsupported(String)

    package var description: String {
        switch self {
        case .missingFunction(let name): return "Shader function '\(name)' not found in the shaders"
        case .resourceCreation(let what): return "Failed to create \(what)"
        case .unsupported(let what): return "This GPU doesn't support \(what), which the renderer needs"
        }
    }
}
