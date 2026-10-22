import Buildings
import Characters
import Effects
import EngineCore
import Materials
import Metal
import Physics
import Plants

/// The pipelines of the passes that take theirs as a group (Pipelines is in the core; these groups are the engine's).
extension Pipelines {
    var rc: RCPipelines {
        RCPipelines(probe: self[.rcProbe], traceMerge: self[.rcTraceMerge], filter: self[.rcFilter], sh: self[.rcSH], clearAmbient: self[.rcClearAmbient],
                    resolve: self[.rcResolve])
    }
    var vg: VGPipelines { VGPipelines(reset: self[.vgReset], cut: self[.vgCut], boxes: self[.vgBoxes]) }
}
