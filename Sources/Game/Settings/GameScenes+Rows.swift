import Buildings
import Characters
import Effects
import EngineCore
import Foundation
import Landscape
import Materials
import MetalRenderer
import Physics
import Plants

extension GameScenes {
    private typealias S = SettingSpec

    /// The settings panel's rows of the game's scenes: their counts (the stress test's objects, the crowd's characters),
    /// their physics, the destruction's and the demolition's. Each shows while its scene is loaded; the engine places
    /// them after the workshops' (SettingsTable.sceneRows).
    static var sceneRows: [SettingSpec] {
        [
            S.custom(.showcaseModel, "Model").when { $0.scene.kind == .showcase },   // the model brings its look
            S.slider("Objects", \.scene.objects, SceneSettings.objectRange, step: 50, live: false)
                .env(.scene, "objects").when { $0.scene.kind == .stress },
            S.slider("Characters", \.scene.characters, SceneSettings.characterRange, log: true, live: false)
                .env(.scene, "characters").when { $0.scene.kind == .crowd },
            S.slider("Poses", \.scene.poses, SceneSettings.poseRange, log: true, live: false)
                .env(.scene, "poses").when { $0.scene.kind == .crowd },
            S.slider("Detail level", \.scene.detail, SceneSettings.detailRange, live: false)
                .env(.scene, "detail").when { $0.scene.kind == .crowd },
            S.popup("Characters", \.scene.crowdBodies, SettingsTable.titled(\.title)).env(.scene, "cast").when { $0.scene.kind == .crowd },
            S.slider("Bodies", \.scene.physics.bodies, PhysicsSettings.bodyRange, step: 16, live: false)
                .env(.scene, "bodies").when { $0.scene.kind == .physics },
            S.slider("Particles", \.scene.physics.particles, PhysicsSettings.particleRange, log: true, live: false)
                .env(.scene, "particles").when { $0.scene.kind == .physics },
            S.slider("Cloth vertices", \.scene.physics.cloth, PhysicsSettings.clothRange, step: 4, live: false) { $0 == 0 ? "none" : "\($0) x \($0)" }
                .env(.scene, "cloth").when { $0.scene.kind == .physics },
            S.slider("Ragdolls", \.scene.physics.ragdolls, PhysicsSettings.ragdollRange, live: false)
                .env(.scene, "ragdolls").when { $0.scene.kind == .ragdolls },
            S.slider("Strands per guide", \.scene.physics.hair, PhysicsSettings.hairRange, live: false)
                .env(.scene, "hair").when { $0.scene.kind == .hair },
            S.slider("Furry bodies", \.scene.physics.furBodies, PhysicsSettings.furBodyRange, live: false)
                .env(.scene, "fur").when { $0.scene.kind == .hair },
            S.slider("Soft bodies", \.scene.physics.softBodies, PhysicsSettings.softBodyRange, live: false)
                .env(.scene, "soft").when { $0.scene.kind == .softBodies },
            S.slider("Lattice cells", \.scene.physics.softCells, PhysicsSettings.softCellRange, live: false)
                .env(.scene, "cells").when { $0.scene.kind == .softBodies },
            S.check("Character", \.scene.physics.muscleCharacter).env(.scene, "character").when { $0.scene.kind == .muscles },
            S.slider("Ragdolls with flesh", \.scene.physics.muscleRagdolls, PhysicsSettings.muscleRagdollRange, live: false)
                .env(.scene, "fleshragdolls").when { $0.scene.kind == .muscles },
            S.slider("Flesh lattice", \.scene.physics.fleshCell, PhysicsSettings.fleshCellRange, step: 0.5, live: false) { String(format: "%.1f cm", $0) }
                .env(.scene, "flesh").when { $0.scene.kind == .muscles },
            S.popup("Body", \.scene.physics.body, SettingsTable.titled(\.title)).env(.scene, "body").when { $0.scene.kind == .muscles },
            S.popup("Skin", \.scene.physics.skin, SettingsTable.titled(\.title)).env(.scene, "skin")
                .when { $0.scene.kind == .muscles && $0.scene.physics.body == .skin },
            S.slider("Muscle strength", \.scene.physics.muscleGain, PhysicsSettings.muscleGainRange, step: 0.05, live: false) { String(format: "%.2f", $0) }
                .env(.scene, "muscle").when { $0.scene.kind == .muscles },
            S.popup("Liquids", \.scene.physics.liquids, SettingsTable.titled(\.title)).env(.scene, "liquid").when { $0.scene.kind == .fluids },
            S.popup("Solver", \.scene.physics.solver, SettingsTable.titled(\.title)).env(.scene, "solver").when { $0.scene.kind == .fluids },
            S.popup("Water", \.scene.physics.waterSolver, SettingsTable.titled(\.title)).env(.scene, "water")
                .when { $0.scene.kind == .fluids && $0.scene.physics.solver == .auto },
            S.popup("Blood", \.scene.physics.bloodSolver, SettingsTable.titled(\.title)).env(.scene, "blood")
                .when { $0.scene.kind == .fluids && $0.scene.physics.solver == .auto },
            S.popup("Honey", \.scene.physics.honeySolver, SettingsTable.titled(\.title)).env(.scene, "honey")
                .when { $0.scene.kind == .fluids && $0.scene.physics.solver == .auto },
            S.slider("Particles per liquid", \.scene.physics.fluidParticles, PhysicsSettings.fluidRange, log: true, live: false)
                .env(.scene, "fluid").when { $0.scene.kind == .fluids },
            S.slider("Pieces", \.scene.destruction.pieces, DestructionSettings.pieceRange, step: 0.25, live: false) { String(format: "%.2fx", $0) }
                .env(.scene, "pieces").when { $0.scene.kind == .destruction },
            S.slider("Toughness", \.scene.destruction.toughness, DestructionSettings.toughnessRange, digits: 2, log: true, live: false) { String(format: "%.2fx", $0) }
                .env(.scene, "toughness").when { $0.scene.kind == .destruction },
            S.slider("Weld strength", \.scene.destruction.strength, DestructionSettings.toughnessRange, digits: 2, log: true, live: false) { String(format: "%.2fx", $0) }
                .env(.scene, "strength").when { $0.scene.kind == .destruction },
            S.check("Dust and debris", \.scene.destruction.dust).env(.scene, "dust").when { $0.scene.kind == .destruction },
            S.check("Small pieces fade", \.scene.destruction.fade).env(.scene, "fade").when { $0.scene.kind == .destruction },
            S.check("Scripted demo", \.scene.destruction.demo).env(.scene, "demo").when { $0.scene.kind == .destruction },
            S.check("Statues (cut meshes)", \.scene.destruction.statues).env(.scene, "statues").when { $0.scene.kind == .destruction },
            S.check("Massive (a building, offline)", \.scene.destruction.massive).env(.scene, "massive").when { $0.scene.kind == .destruction },
            S.slider("Buildings", \.scene.destruction.buildings, DestructionSettings.buildingRange, live: false).env(.scene, "buildings")
                .when { $0.scene.kind == .destruction && $0.scene.destruction.massive },
            S.popup("Car", \.scene.cars.style, SettingsTable.titled(\.title)).env(.scene, "carstyle").when { $0.scene.kind == .cars },
            S.slider("Cars", \.scene.cars.cars, CarSettings.carRange, live: false).env(.scene, "carcount").when { $0.scene.kind == .cars },
            S.popup("Demo", \.scene.cars.demo, SettingsTable.titled(\.title)).env(.scene, "cardemo").when { $0.scene.kind == .cars },
            S.slider("Demo speed", \.scene.cars.demoSpeed, CarSettings.speedRange, step: 5, live: false) { String(format: "%.0f km/h", $0) }
                .env(.scene, "carspeed").when { $0.scene.kind == .cars && $0.scene.cars.demo.crashes },
            S.check("Traction control and ABS", \.scene.cars.assists).env(.scene, "carassists").when { $0.scene.kind == .cars },
            S.slider("Storeys", \.scene.demolition.floors, DemolitionSettings.floorRange, live: false).env(.scene, "demfloors")
                .when { $0.scene.kind == .demolition },
            S.slider("Office seed", \.scene.demolition.seed, DemolitionSettings.seedRange, live: false).env(.scene, "demseed")
                .when { $0.scene.kind == .demolition },
            S.slider("Width", \.scene.demolition.width, DemolitionSettings.sizeRange, step: 1, live: false) { String(format: "%.0f m", $0) }
                .env(.scene, "demwidth").when { $0.scene.kind == .demolition },
            S.slider("Depth", \.scene.demolition.depth, DemolitionSettings.sizeRange, step: 1, live: false) { String(format: "%.0f m", $0) }
                .env(.scene, "demdepth").when { $0.scene.kind == .demolition },
            S.slider("Pieces", \.scene.demolition.pieces, DemolitionSettings.pieceRange, step: 0.25, live: false) { String(format: "%.2fx", $0) }
                .env(.scene, "dempieces").when { $0.scene.kind == .demolition },
            S.slider("Toughness", \.scene.demolition.toughness, DemolitionSettings.toughnessRange, digits: 2, log: true, live: false) { String(format: "%.2fx", $0) }
                .env(.scene, "demtough").when { $0.scene.kind == .demolition },
            S.slider("Weld strength", \.scene.demolition.strength, DemolitionSettings.toughnessRange, digits: 2, log: true, live: false) { String(format: "%.2fx", $0) }
                .env(.scene, "demstrength").when { $0.scene.kind == .demolition },
            S.check("Furniture", \.scene.demolition.furniture).env(.scene, "demfurniture").when { $0.scene.kind == .demolition },
            S.check("Window glass", \.scene.demolition.glass).env(.scene, "demglass").when { $0.scene.kind == .demolition },
            S.check("Dust and debris", \.scene.demolition.dust).env(.scene, "demdust").when { $0.scene.kind == .demolition },
            S.check("Small pieces fade", \.scene.demolition.fade).env(.scene, "demfade").when { $0.scene.kind == .demolition },
            S.check("Scripted demo", \.scene.demolition.demo).env(.scene, "demdemo").when { $0.scene.kind == .demolition },
        ]
    }
}
