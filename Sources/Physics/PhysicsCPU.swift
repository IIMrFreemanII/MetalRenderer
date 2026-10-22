import EngineCore
import Foundation
import simd
import CPhysicsAtomics

/// The CPU's step: the reference the GPU's (Shaders/Physics.metal) is checked against, and the backend for scenes with
/// few bodies, where a GPU dispatch costs more than the work. Each stage is what a kernel does, over every body, in
/// the same order. Contacts are solved a colour at a time (Gauss-Seidel): no two pairs of a colour share a body, so
/// the GPU solves a colour's pairs at once and gets the same numbers. So are the joints, after the contacts.
extension PhysicsWorld {
    /// A step (1/60 s), its stages on PhysicsPool's workers.
    package func step() {
        PhysicsPool.shared.run { stepStages() }
    }



    private func stepStages() {
        _ = shapeData   // (made here, if the shapes changed: the stages read it from every core)
        let p = params
        if fractures { beginFractureStep() }   // the shots and blasts of this step (Physics+Fracture.swift)
        broadPhase(p)
        wake(p)
        link()
        particleBroadPhase(p)
        // The liquids before each group of substeps (PhysicsFluidCPU.swift), against the bodies where they are, and
        // what they push the bodies by, before the group's contacts.
        stepFluids()
        listMoving()
        let start = bodies.map { SIMD8<Float>(lowHalf: $0.position, highHalf: $0.rotation) }
        narrowPhase(p, refresh: false)
        colourPairs()
        for sub in 0..<substeps {
            // The contacts again where the substeps have taken the bodies: found once a step, a turning body's
            // contacts stay where it was (a rolling rim's sinks into the floor, and the push out of it launches it).
            if sub > 0 && sub % PhysicsWorld.contactRefresh == 0 {
                stepFluids()
                listMoving()
                narrowPhase(p, refresh: true)
            }
            integrate(p, sub: sub)
            integrateParticles(p)
            solveFlesh(p)       // the muscles, and the flesh held to its bones where this substep moved them
            solveCloth(p)
            solveTets(p)
            solveSkin(p)
            solveParticles(p)   // against the bodies where this substep moved them, before they are pushed apart
            solvePositions(p)
            solveVelocities(p)
        }
        settle(p, start)
        stepHair(start)
        if fractures { endFractureStep() }     // what broke, what came free, what faded
        stepIndex += 1
    }
}

