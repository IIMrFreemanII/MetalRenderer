import Foundation
import simd

/// Mireland: the swamp materials of the collection "Welcome to Mireland" (Sherif Dawoud, Substance 3D Assets),
/// made again as our own graphs by eye from its previews (no file of theirs is read). Six tile: the mud, the gnarly and
/// the birch bark, the loose dirt, the dead grass, the swamp's water with its duckweed. Five are cut out (an opacity
/// output: a card or a decal on the ground): the mud's cracked crust, a puddle, fallen leaves, a clump of grass blades
/// and a leafy stem. The Mireland scene (Scene+Mireland.swift) puts them all in a swamp.
extension MaterialLibrary {
    static let mireland: [MaterialGraph] = [swampMud(), swampMudCracks(), swampMudPuddle(), swampGnarlyBark(), swampBirchBark(),
                                            swampLooseDirt(), swampDeadGrass(), swampGround(), swampLeaves(), swampGrassBlades(), swampPlant()]

    /// Grey-brown mud, lumpy, with pebbles pressed in, wet and dark in its hollows, flecked with algae.
    static func swampMud() -> MaterialGraph {
        var b = MatBuilder("Swamp Mud")
        let lumps = b.node(.fractalSum, ["scale": .int(4), "octaves": .int(7), "roughness": .float(0.55), "mode": .choice("billow")])
        let pebbles = b.node(.tileSampler, ["columns": .int(20), "rows": .int(20), "kind": .choice("hemisphere"), "size": .float(0.55),
                                            "sizeRandom": .float(0.7), "positionRandom": .float(1), "lumRandom": .float(0.5), "seed": .int(3)])
        let sunk = b.node(.levels, ["outHigh": .float(0.75)], ["in": pebbles])
        let ground = b.node(.heightBlend, ["offset": .float(0.45), "contrast": .float(0.75)], ["top": sunk, "bottom": lumps])
        let eroded = b.node(.slopeBlur, ["samples": .int(8), "intensity": .float(0.02)], ["in": ground, "slope": lumps])
        let height = b.node(.autoLevels, [:], ["in": eroded])
        let wet = b.node(.histogramScan, ["position": .float(0.85), "contrast": .float(0.6), "invert": .bool(true)], ["in": height])
        let specks = b.node(.tileSampler, ["columns": .int(64), "rows": .int(64), "kind": .choice("disc"), "size": .float(0.3),
                                           "sizeRandom": .float(0.8), "positionRandom": .float(1), "lumRandom": .float(0.3), "seed": .int(9)])
        let patches = b.node(.grunge, ["scale": .int(3), "contrast": .float(0.7), "spots": .float(0.2), "seed": .int(4)])
        let where_ = b.node(.histogramScan, ["position": .float(0.45), "contrast": .float(0.6)], ["in": patches])
        let algae = b.node(.blend, ["mode": .choice("multiply")], ["fg": where_, "bg": specks])
        let algaeMask = b.node(.histogramScan, ["position": .float(0.8), "contrast": .float(0.9)], ["in": algae])
        let mud = b.node(.gradientMap, ["gradient": gradient((0, [0.2, 0.19, 0.17]), (0.5, [0.38, 0.36, 0.33]), (1, [0.52, 0.5, 0.46]))], ["in": height])
        let dark = b.node(.uniformColor, ["color": rgb(0.09, 0.085, 0.07)])
        let soaked = b.node(.blend, ["mode": .choice("copy"), "opacity": .float(0.5)], ["fg": dark, "bg": mud, "mask": wet])
        let green = b.node(.gradientMap, ["gradient": gradient((0, [0.25, 0.3, 0.07]), (1, [0.46, 0.5, 0.14]))], ["in": specks])
        let color = b.node(.blend, ["mode": .choice("copy")], ["fg": green, "bg": soaked, "mask": algaeMask])
        let dry = b.node(.uniform, ["value": .float(0.9)]), shiny = b.node(.uniform, ["value": .float(0.45)])
        let rough = b.node(.blend, ["mode": .choice("copy")], ["fg": shiny, "bg": dry, "mask": wet])
        b.output(.baseColor, color)
        b.output(.roughness, rough)
        b.output(.height, height)
        b.output(.normal, b.node(.normal, ["intensity": .float(1.5)], ["in": height]))
        b.output(.ambientOcclusion, b.node(.ambientOcclusion, ["radius": .float(0.03), "depth": .float(0.05)], ["in": height]))
        b.set { $0.surface.heightDepth = 0.04; $0.surface.displacement = 0.03; $0.surface.uvScale = 0.5 }
        return b.graph
    }

    /// A crust of dried mud broken into curled plates, its cracks open (cut out: the ground shows through), its edge ragged.
    static func swampMudCracks() -> MaterialGraph {
        var b = MatBuilder("Swamp Mud Cracks")
        let edges = b.node(.cells, ["scale": .int(7), "jitter": .float(0.9), "mode": .choice("borders"), "seed": .int(2)])
        let shade = b.node(.cells, ["scale": .int(7), "jitter": .float(0.9), "mode": .choice("cellValue"), "seed": .int(2)])
        let plates = b.node(.histogramScan, ["position": .float(0.97), "contrast": .float(0.95)], ["in": edges])
        let beveled = b.node(.bevel, ["distance": .float(0.025), "smoothing": .float(0.6)], ["in": plates])
        let curl = b.node(.levels, ["outLow": .float(1), "outHigh": .float(0.55)], ["in": beveled])     // the plates' edges lifted
        let raised = b.node(.blend, ["mode": .choice("multiply")], ["fg": plates, "bg": curl])
        let grain = b.node(.fractalSum, ["scale": .int(12), "octaves": .int(5), "roughness": .float(0.5)])
        let height = b.node(.blend, ["mode": .choice("multiply"), "opacity": .float(0.3)], ["fg": grain, "bg": raised])
        let disc = b.node(.shape, ["kind": .choice("disc"), "size": .float(0.95), "softness": .float(0.45)])
        let rag = b.node(.grunge, ["scale": .int(4), "contrast": .float(0.6), "spots": .float(0.3), "seed": .int(6)])
        let warped = b.node(.warp, ["intensity": .float(0.12)], ["in": disc, "gradient": rag])
        let patch = b.node(.histogramScan, ["position": .float(0.88), "contrast": .float(0.85)], ["in": warped])
        let opacity = b.node(.blend, ["mode": .choice("multiply")], ["fg": plates, "bg": patch])
        let tone = b.node(.blend, ["mode": .choice("overlay"), "opacity": .float(0.4)], ["fg": grain, "bg": shade])
        let crust = b.node(.gradientMap, ["gradient": gradient((0, [0.3, 0.28, 0.24]), (0.6, [0.44, 0.41, 0.36]), (1, [0.52, 0.49, 0.43]))], ["in": tone])
        let rims = b.node(.blend, ["mode": .choice("multiply"), "opacity": .float(0.5)], ["fg": beveled, "bg": crust])
        b.output(.baseColor, rims)
        b.output(.opacity, opacity)
        b.output(.roughness, b.node(.uniform, ["value": .float(0.92)]))
        b.output(.height, height)
        b.output(.normal, b.node(.normal, ["intensity": .float(5)], ["in": height]))
        b.output(.ambientOcclusion, b.node(.ambientOcclusion, ["radius": .float(0.02), "depth": .float(0.04)], ["in": height]))
        b.set { $0.surface.heightDepth = 0.01 }
        return b.graph
    }

    /// A puddle of still black water in a ring of wet mud, its edge ragged (cut out: a decal on the ground).
    static func swampMudPuddle() -> MaterialGraph {
        var b = MatBuilder("Swamp Mud Puddle")
        let disc = b.node(.shape, ["kind": .choice("disc"), "size": .float(0.95), "softness": .float(0.9)])
        let wobble = b.node(.fractalSum, ["scale": .int(3), "octaves": .int(5), "roughness": .float(0.5), "seed": .int(8)])
        let warped = b.node(.warp, ["intensity": .float(0.18)], ["in": disc, "gradient": wobble])
        let patch = b.node(.histogramScan, ["position": .float(0.88), "contrast": .float(0.8)], ["in": warped])
        let pool = b.node(.histogramScan, ["position": .float(0.45), "contrast": .float(0.92)], ["in": warped])
        let rim = b.node(.histogramScan, ["position": .float(0.58), "contrast": .float(0.5)], ["in": warped])
        let clumps = b.node(.fractalSum, ["scale": .int(10), "octaves": .int(6), "roughness": .float(0.55), "mode": .choice("billow")])
        let still = b.node(.uniform, ["value": .float(0.25)])
        let height = b.node(.blend, ["mode": .choice("copy")], ["fg": still, "bg": clumps, "mask": pool])
        let mud = b.node(.gradientMap, ["gradient": gradient((0, [0.18, 0.16, 0.13]), (0.6, [0.36, 0.33, 0.28]), (1, [0.48, 0.44, 0.38]))], ["in": clumps])
        let wetMud = b.node(.uniformColor, ["color": rgb(0.13, 0.115, 0.095)])
        let soaked = b.node(.blend, ["mode": .choice("copy"), "opacity": .float(0.8)], ["fg": wetMud, "bg": mud, "mask": rim])
        let water = b.node(.uniformColor, ["color": rgb(0.035, 0.035, 0.03)])
        let color = b.node(.blend, ["mode": .choice("copy")], ["fg": water, "bg": soaked, "mask": pool])
        let dry = b.node(.uniform, ["value": .float(0.8)]), damp = b.node(.uniform, ["value": .float(0.35)]), glass = b.node(.uniform, ["value": .float(0.03)])
        let r1 = b.node(.blend, ["mode": .choice("copy")], ["fg": damp, "bg": dry, "mask": rim])
        let rough = b.node(.blend, ["mode": .choice("copy")], ["fg": glass, "bg": r1, "mask": pool])
        b.output(.baseColor, color)
        b.output(.opacity, patch)
        b.output(.roughness, rough)
        b.output(.height, height)
        b.output(.normal, b.node(.normal, ["intensity": .float(3)], ["in": height]))
        b.set { $0.surface.heightDepth = 0.008 }
        return b.graph
    }

    /// Old pale bark twisted into fibrous ridges, deep grooves between them.
    static func swampGnarlyBark() -> MaterialGraph {
        var b = MatBuilder("Swamp Gnarly Bark")
        let streaks = b.node(.anisotropicNoise, ["scaleX": .int(3), "scaleY": .int(40), "smoothness": .float(0.8)])
        let upright = b.node(.transform, ["rotation": .float(0.25)], ["in": streaks])
        let twist = b.node(.fractalSum, ["scale": .int(3), "octaves": .int(5), "roughness": .float(0.5), "seed": .int(12)])
        let warped = b.node(.directionalWarp, ["amount": .float(0.08), "angle": .float(0)], ["in": upright, "intensity": twist])
        let fibres = b.node(.fibers, ["count": .int(6), "length": .float(0.5), "width": .float(0.012), "angle": .float(0.25),
                                      "angleRandom": .float(0.08), "curvature": .float(0.2), "scale": .int(4), "seed": .int(5)])
        let ridges = b.node(.blend, ["mode": .choice("screen"), "opacity": .float(0.5)], ["fg": fibres, "bg": warped])
        let worn = b.node(.slopeBlur, ["samples": .int(8), "intensity": .float(0.02)], ["in": ridges, "slope": twist])
        let height = b.node(.autoLevels, [:], ["in": worn])
        let grain = b.node(.fractalSum, ["scale": .int(24), "octaves": .int(4), "roughness": .float(0.5)])
        let tone = b.node(.blend, ["mode": .choice("overlay"), "opacity": .float(0.3)], ["fg": grain, "bg": height])
        let color = b.node(.gradientMap, ["gradient": gradient((0, [0.11, 0.09, 0.075]), (0.45, [0.38, 0.34, 0.29]), (1, [0.66, 0.62, 0.55]))], ["in": tone])
        b.output(.baseColor, color)
        b.output(.roughness, b.node(.levels, ["outLow": .float(0.92), "outHigh": .float(0.7)], ["in": height]))
        b.output(.height, height)
        b.output(.normal, b.node(.normal, ["intensity": .float(6)], ["in": height]))
        b.output(.ambientOcclusion, b.node(.ambientOcclusion, ["radius": .float(0.03), "depth": .float(0.08)], ["in": height]))
        b.set { $0.surface.heightDepth = 0.05; $0.surface.displacement = 0.03; $0.surface.displacementDetail = 0.04 }
        return b.graph
    }

    /// Birch: chalk-white bark banded in greys, short dark lenticels across it, peeled patches dark brown.
    static func swampBirchBark() -> MaterialGraph {
        var b = MatBuilder("Swamp Birch Bark")
        let bands = b.node(.anisotropicNoise, ["scaleX": .int(2), "scaleY": .int(64), "smoothness": .float(0.6)])
        let clouds = b.node(.fractalSum, ["scale": .int(6), "octaves": .int(6), "roughness": .float(0.5)])
        let base = b.node(.blend, ["mode": .choice("multiply"), "opacity": .float(0.5)], ["fg": bands, "bg": clouds])
        let lenticels = b.node(.scratches, ["count": .int(3), "length": .float(0.12), "width": .float(0.007), "angle": .float(0),
                                            "angleRandom": .float(0.04), "intensityRandom": .float(0.4), "scale": .int(10), "seed": .int(3)])
        let marks = b.node(.histogramScan, ["position": .float(0.7), "contrast": .float(0.8)], ["in": lenticels])
        let crystals = b.node(.cells, ["scale": .int(5), "mode": .choice("crystal"), "seed": .int(7)])
        let dirt = b.node(.grunge, ["scale": .int(3), "contrast": .float(0.6), "spots": .float(0.4), "seed": .int(9)])
        let peelArea = b.node(.blend, ["mode": .choice("multiply")], ["fg": dirt, "bg": crystals])
        let peel = b.node(.histogramScan, ["position": .float(0.38), "contrast": .float(0.9)], ["in": peelArea])
        let white = b.node(.gradientMap, ["gradient": gradient((0, [0.62, 0.61, 0.58]), (0.6, [0.8, 0.79, 0.76]), (1, [0.88, 0.87, 0.84]))], ["in": base])
        let black = b.node(.uniformColor, ["color": rgb(0.12, 0.1, 0.09)])
        let brown = b.node(.uniformColor, ["color": rgb(0.24, 0.17, 0.12)])
        let marked = b.node(.blend, ["mode": .choice("copy")], ["fg": black, "bg": white, "mask": marks])
        let color = b.node(.blend, ["mode": .choice("copy")], ["fg": brown, "bg": marked, "mask": peel])
        let cutIn = b.node(.blend, ["mode": .choice("subtract"), "opacity": .float(0.35)], ["fg": marks, "bg": base])
        let height = b.node(.blend, ["mode": .choice("subtract"), "opacity": .float(0.25)], ["fg": peel, "bg": cutIn])
        b.output(.baseColor, color)
        b.output(.roughness, b.node(.levels, ["outLow": .float(0.55), "outHigh": .float(0.75)], ["in": peel]))
        b.output(.height, height)
        b.output(.normal, b.node(.normal, ["intensity": .float(3)], ["in": height]))
        b.output(.ambientOcclusion, b.node(.ambientOcclusion, ["radius": .float(0.02), "depth": .float(0.03)], ["in": height]))
        b.set { $0.surface.heightDepth = 0.01; $0.surface.displacement = 0.005 }
        return b.graph
    }

    /// Crumbly brown soil, clods and small pebbles in it.
    static func swampLooseDirt() -> MaterialGraph {
        var b = MatBuilder("Swamp Loose Dirt")
        let clods = b.node(.cells, ["scale": .int(18), "jitter": .float(1), "mode": .choice("f1"), "seed": .int(4)])
        let domes = b.node(.levels, ["inHigh": .float(0.9), "gamma": .float(0.7), "outLow": .float(1), "outHigh": .float(0)], ["in": clods])
        let grain = b.node(.fractalSum, ["scale": .int(28), "octaves": .int(5), "roughness": .float(0.55)])
        let soil = b.node(.blend, ["mode": .choice("multiply"), "opacity": .float(0.6)], ["fg": grain, "bg": domes])
        let pebbles = b.node(.tileSampler, ["columns": .int(28), "rows": .int(28), "kind": .choice("hemisphere"), "size": .float(0.45),
                                            "sizeRandom": .float(0.7), "positionRandom": .float(1), "lumRandom": .float(0.4), "seed": .int(7)])
        let mixed = b.node(.heightBlend, ["offset": .float(0.55), "contrast": .float(0.85)], ["top": pebbles, "bottom": soil])
        let earth = b.node(.gradientMap, ["gradient": gradient((0, [0.14, 0.11, 0.08]), (0.5, [0.31, 0.25, 0.19]), (1, [0.43, 0.35, 0.27]))], ["in": soil])
        let stone = b.node(.gradientMap, ["gradient": gradient((0, [0.26, 0.24, 0.21]), (1, [0.48, 0.45, 0.4]))], ["in": pebbles])
        let color = b.node(.blend, ["mode": .choice("copy")], ["fg": stone, "bg": earth, "mask": mixed["mask"]])
        b.output(.baseColor, color)
        b.output(.roughness, b.node(.uniform, ["value": .float(0.9)]))
        b.output(.height, mixed)
        b.output(.normal, b.node(.normal, ["intensity": .float(5)], ["in": mixed]))
        b.output(.ambientOcclusion, b.node(.ambientOcclusion, ["radius": .float(0.02), "depth": .float(0.05)], ["in": mixed]))
        b.set { $0.surface.heightDepth = 0.03; $0.surface.displacement = 0.02 }
        return b.graph
    }

    /// Dead grass lying every way in layers over dark soil: straw yellow on top, darker beneath.
    static func swampDeadGrass() -> MaterialGraph {
        var b = MatBuilder("Swamp Dead Grass")
        func layer(_ seed: Int, _ scale: Int, _ width: Float, _ length: Float, _ top: Float) -> MatBuilder.Ref {
            let f = b.node(.fibers, ["count": .int(8), "length": .float(length), "width": .float(width), "angle": .float(0), "angleRandom": .float(1),
                                     "curvature": .float(0.3), "intensityRandom": .float(0.4), "scale": .int(scale), "seed": .int(seed)])
            return b.node(.levels, ["outHigh": .float(top)], ["in": f])
        }
        let deep = layer(1, 5, 0.008, 0.35, 0.55), mid = layer(2, 6, 0.006, 0.28, 0.8), top = layer(3, 8, 0.005, 0.22, 1)
        let two = b.node(.blend, ["mode": .choice("lighten")], ["fg": mid, "bg": deep])
        let straw = b.node(.blend, ["mode": .choice("lighten")], ["fg": top, "bg": two])
        let soilNoise = b.node(.fractalSum, ["scale": .int(8), "octaves": .int(6), "roughness": .float(0.5)])
        let soilLow = b.node(.levels, ["outHigh": .float(0.2)], ["in": soilNoise])
        let height = b.node(.blend, ["mode": .choice("lighten")], ["fg": straw, "bg": soilLow])
        let covered = b.node(.histogramScan, ["position": .float(0.92), "contrast": .float(0.9)], ["in": straw])
        let soil = b.node(.gradientMap, ["gradient": gradient((0, [0.07, 0.06, 0.045]), (1, [0.16, 0.13, 0.1]))], ["in": soilNoise])
        let strawColor = b.node(.gradientMap, ["gradient": gradient((0, [0.22, 0.17, 0.1]), (0.5, [0.5, 0.41, 0.26]), (1, [0.74, 0.65, 0.45]))],
                                ["in": straw])
        let color = b.node(.blend, ["mode": .choice("copy")], ["fg": strawColor, "bg": soil, "mask": covered])
        b.output(.baseColor, color)
        b.output(.roughness, b.node(.uniform, ["value": .float(0.85)]))
        b.output(.height, height)
        b.output(.normal, b.node(.normal, ["intensity": .float(4)], ["in": height]))
        b.output(.ambientOcclusion, b.node(.ambientOcclusion, ["radius": .float(0.02), "depth": .float(0.06)], ["in": height]))
        b.set { $0.surface.heightDepth = 0.03; $0.surface.displacement = 0.015 }
        return b.graph
    }

    /// The swamp's water: black-green and glassy, duckweed drifting on it in rafts, twigs floating.
    static func swampGround() -> MaterialGraph {
        var b = MatBuilder("Swamp Ground")
        let weed = b.node(.tileSampler, ["columns": .int(80), "rows": .int(80), "kind": .choice("disc"), "size": .float(0.75),
                                         "sizeRandom": .float(0.5), "positionRandom": .float(1), "lumRandom": .float(0.35), "seed": .int(11)])
        let drift = b.node(.fractalSum, ["scale": .int(4), "octaves": .int(6), "roughness": .float(0.55), "seed": .int(13)])
        let rafts = b.node(.histogramScan, ["position": .float(0.42), "contrast": .float(0.6)], ["in": drift])
        let floating = b.node(.blend, ["mode": .choice("multiply")], ["fg": rafts, "bg": weed])
        let weedMask = b.node(.histogramScan, ["position": .float(0.9), "contrast": .float(0.95)], ["in": floating])
        let twigs = b.node(.fibers, ["count": .int(2), "length": .float(0.3), "width": .float(0.005), "angle": .float(0), "angleRandom": .float(1),
                                     "curvature": .float(0.1), "scale": .int(4), "seed": .int(17)])
        let twigMask = b.node(.histogramScan, ["position": .float(0.9), "contrast": .float(0.9)], ["in": twigs])
        let water = b.node(.uniformColor, ["color": rgb(0.035, 0.042, 0.03)])
        let green = b.node(.gradientMap, ["gradient": gradient((0, [0.16, 0.25, 0.05]), (1, [0.42, 0.52, 0.12]))], ["in": weed])
        let wood = b.node(.uniformColor, ["color": rgb(0.2, 0.15, 0.09)])
        let weedy = b.node(.blend, ["mode": .choice("copy")], ["fg": green, "bg": water, "mask": weedMask])
        let color = b.node(.blend, ["mode": .choice("copy")], ["fg": wood, "bg": weedy, "mask": twigMask])
        let glassy = b.node(.uniform, ["value": .float(0.03)]), leafy = b.node(.uniform, ["value": .float(0.55)]), bark = b.node(.uniform, ["value": .float(0.75)])
        let r1 = b.node(.blend, ["mode": .choice("copy")], ["fg": leafy, "bg": glassy, "mask": weedMask])
        let rough = b.node(.blend, ["mode": .choice("copy")], ["fg": bark, "bg": r1, "mask": twigMask])
        let height = b.node(.blend, ["mode": .choice("lighten")], ["fg": twigs, "bg": floating])
        b.output(.baseColor, color)
        b.output(.roughness, rough)
        b.output(.height, height)
        b.output(.normal, b.node(.normal, ["intensity": .float(0.8)], ["in": height]))
        b.set { $0.surface.heightDepth = 0.004 }
        return b.graph
    }

    /// Fallen leaves, every way up, yellow, brown and olive (cut out: a decal on the ground).
    static func swampLeaves() -> MaterialGraph {
        var b = MatBuilder("Swamp Leaves")
        let leaf = b.node(.shape, ["kind": .choice("leaf"), "size": .float(0.95), "softness": .float(0.04)])
        let leaves = b.node(.tileSampler, ["columns": .int(6), "rows": .int(6), "size": .float(1.1), "sizeRandom": .float(0.4),
                                           "positionRandom": .float(1), "rotationRandom": .float(1), "lumRandom": .float(0.6), "seed": .int(5)],
                            ["pattern": leaf])
        let opacity = b.node(.histogramScan, ["position": .float(0.98), "contrast": .float(0.95)], ["in": leaves])
        let veins = b.node(.fractalSum, ["scale": .int(32), "octaves": .int(4), "roughness": .float(0.5)])
        let tone = b.node(.blend, ["mode": .choice("multiply"), "opacity": .float(0.2)], ["fg": veins, "bg": leaves])
        let color = b.node(.gradientMap, ["gradient": gradient((0, [0.16, 0.09, 0.04]), (0.35, [0.38, 0.22, 0.08]), (0.7, [0.6, 0.45, 0.15]),
                                                               (1, [0.5, 0.5, 0.17]))], ["in": tone])
        b.output(.baseColor, color)
        b.output(.opacity, opacity)
        b.output(.roughness, b.node(.uniform, ["value": .float(0.7)]))
        b.output(.height, leaves)
        b.output(.normal, b.node(.normal, ["intensity": .float(3)], ["in": leaves]))
        b.set { $0.surface.heightDepth = 0.005 }
        return b.graph
    }

    /// A clump of grass blades fanned from one root, dark at the root, yellow-green to the tips (a card, cut out).
    static func swampGrassBlades() -> MaterialGraph {
        var b = MatBuilder("Swamp Grass Blades")
        let code = """
        float2 xy = float2(uv.x - 0.5, 1.0 - uv.y);
        float cov = 0.0, h = 0.0, tone = 0.0;
        for (int i = 0; i < 16; i++) {
            float r0 = matRand(uint2(uint(i), 1u), uint(seed)), r1 = matRand(uint2(uint(i), 2u), uint(seed)), r2 = matRand(uint2(uint(i), 3u), uint(seed));
            float ang = (float(i) / 15.0 - 0.5) * 1.3 + (r0 - 0.5) * 0.25;
            float len = mix(0.55, 0.95, r1);
            float bend = (r2 - 0.5) * 0.5 + sign(ang) * 0.25;
            float2 dir = float2(sin(ang), cos(ang)), side = float2(dir.y, -dir.x);
            float2 q = xy - float2(0.0, 0.02);
            float t = dot(q, dir) / len;
            if (t < 0.0 || t > 1.0) continue;
            float x = dot(q, side) - bend * t * t * len;
            float hw = 0.022 * pow(1.0 - t, 0.6) + 0.0015;
            float a = abs(x) / hw;
            if (a >= 1.0) continue;
            float v = sqrt(1.0 - a * a) * (0.6 + 0.4 * t);
            if (v > h) { h = v; tone = saturate(t * 0.8 + r0 * 0.25); }
            cov = 1.0;
        }
        return float4(cov, h, tone, 1.0);
        """
        let clump = b.node(.code, ["mode": .choice("color"), "code": .text(code)])
        let split = b.node(.rgbaSplit, [:], ["in": clump])
        let color = b.node(.gradientMap, ["gradient": gradient((0, [0.08, 0.09, 0.04]), (0.35, [0.3, 0.36, 0.1]), (0.75, [0.58, 0.58, 0.22]),
                                                               (1, [0.72, 0.66, 0.34]))], ["in": split["b"]])
        b.output(.baseColor, color)
        b.output(.opacity, split["r"])
        b.output(.roughness, b.node(.uniform, ["value": .float(0.6)]))
        b.output(.height, split["g"])
        b.output(.normal, b.node(.normal, ["intensity": .float(2)], ["in": split["g"]]))
        b.set { $0.surface.heightDepth = 0; $0.surface.alphaCutoff = 0.5 }
        return b.graph
    }

    /// A slender stem, gently bent, its narrow pale leaves alternating up it (a card, cut out).
    static func swampPlant() -> MaterialGraph {
        var b = MatBuilder("Swamp Plant")
        let code = """
        float2 xy = float2(uv.x - 0.5, 1.0 - uv.y);
        float cov = 0.0, h = 0.0, tone = 0.0;
        float sx = 0.08 * xy.y * xy.y - 0.02 * xy.y;
        float sw = mix(0.010, 0.003, saturate(xy.y));
        float ds = abs(xy.x - sx);
        if (xy.y > 0.0 && xy.y < 0.97 && ds < sw) { cov = 1.0; h = 0.5 * sqrt(1.0 - (ds / sw) * (ds / sw)); tone = 0.05; }
        for (int i = 0; i < 13; i++) {
            float t = 0.2 + float(i) * 0.06;
            float side = (i % 2 == 0) ? 1.0 : -1.0;
            float r0 = matRand(uint2(uint(i), 5u), uint(seed));
            float2 base = float2(0.08 * t * t - 0.02 * t, t);
            float ang = side * (1.05 - 0.75 * t + (r0 - 0.5) * 0.2);
            float len = mix(0.24, 0.10, (t - 0.2) / 0.75);
            float2 dir = float2(sin(ang), cos(ang)), across = float2(dir.y, -dir.x);
            float2 q = xy - base;
            float al = dot(q, dir) / len;
            if (al < 0.0 || al > 1.0) continue;
            float hw = 0.16 * len * pow(sin(al * 3.14159), 0.8) + 1e-4;
            float x = dot(q, across) - 0.06 * len * sin(al * 3.14159) * side;
            float a = abs(x) / hw;
            if (a >= 1.0) continue;
            float v = sqrt(1.0 - a * a) * (1.0 - 0.35 * exp(-x * x / (hw * hw * 0.02)));
            if (v > h) { h = v; tone = 0.4 + 0.6 * r0; }
            cov = 1.0;
        }
        return float4(cov, h, tone, 1.0);
        """
        let plant = b.node(.code, ["mode": .choice("color"), "code": .text(code)])
        let split = b.node(.rgbaSplit, [:], ["in": plant])
        let color = b.node(.gradientMap, ["gradient": gradient((0, [0.22, 0.27, 0.09]), (0.3, [0.4, 0.45, 0.15]), (0.7, [0.62, 0.62, 0.26]),
                                                               (1, [0.76, 0.72, 0.38]))], ["in": split["b"]])
        b.output(.baseColor, color)
        b.output(.opacity, split["r"])
        b.output(.roughness, b.node(.uniform, ["value": .float(0.55)]))
        b.output(.height, split["g"])
        b.output(.normal, b.node(.normal, ["intensity": .float(2)], ["in": split["g"]]))
        b.set { $0.surface.heightDepth = 0; $0.surface.alphaCutoff = 0.5 }
        return b.graph
    }
}
