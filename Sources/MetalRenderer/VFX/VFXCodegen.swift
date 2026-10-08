import Foundation
import simd

/// The Metal an emitter's program is (VFXProgram): its birth, step and look as the fixed emitter's code
/// (Shaders/ParticleSim.metal particleSpawn, particleStep, particlePoseKernel) has them, statement for statement, with
/// what the graph wires in their place. And the dispatchers the kernels' hooks call (vfxSpawn, vfxStep, vfxOutput),
/// a case a program.
extension VFXProgramBuilder {
    /// The program of this emitter (number `number` in its system), or nil if the fixed emitter does all it asks.
    func build(number: Int) throws -> VFXProgram? {
        let em = emitter
        var hooks: VFXProgram.Hooks = []
        var initPlan = VFXInitPlan(), stepPlan = VFXStepPlan(), outputPlan = VFXOutputPlan()
        var rate: Int?

        // Spawn: a rate that a curve scales over time.
        if let r = em.first(.rate) {
            let c = r.param("overTime").curve
            if !c.keys.allSatisfy({ $0.y == 1 }) {
                let k = curveSlot("\(r.id).overTime", c)
                adjust(k) { $0.z = max(r.float("span"), ParticleSystem.stepLength) / ParticleSystem.stepLength }
                rate = k
                hooks.insert(.rate)
            }
        }
        // Initialize, in its blocks' order.
        for b in em.initialize where b.enabled {
            switch b.kind {
            case .lifetime where wired(b.id, "lifetime"):
                initPlan.ops.append((.lifetime, try input(b.id, "lifetime", b.param("lifetime"), as: .float, in: .initialize)))
            case .setPosition:
                initPlan.ops.append((.position, try input(b.id, "value", b.param("value"), as: .vec3, in: .initialize)))
            case .setVelocity:
                initPlan.ops.append((.velocity, try input(b.id, "value", b.param("value"), as: .vec3, in: .initialize)))
            case .setAttribute:
                let k = attribute(b.choice("attribute"))
                initPlan.ops.append((.attribute(k), try input(b.id, "value", b.param("value"), as: .color, in: .initialize)))
            default: break
            }
        }
        if !initPlan.ops.isEmpty { hooks.insert(.spawn) }
        // Update: wired shares of the fixed forces, and the blocks only generated code has.
        func share(_ b: VFXBlock, _ pin: String) throws -> VFXExpr? {
            wired(b.id, pin) ? try input(b.id, pin, b.param(pin), as: .float, in: .update) : nil
        }
        for b in em.update where b.enabled {
            switch b.kind {
            case .gravity: stepPlan.gravity = try share(b, "share")
            case .drag:
                stepPlan.drag = try share(b, "drag")
                stepPlan.wind = try share(b, "wind")
            case .curl: stepPlan.curl = try share(b, "strength")
            case .field: stepPlan.field = try share(b, "strength")
            case .vortex:
                stepPlan.swirl = try share(b, "swirl")
                stepPlan.attraction = try share(b, "attraction")
            case .force: stepPlan.forces.append(try input(b.id, "force", b.param("force"), as: .vec3, in: .update))
            case .setVelocity: stepPlan.velocities.append(try input(b.id, "value", b.param("value"), as: .vec3, in: .update))
            case .setAttribute:
                let k = attribute(b.choice("attribute"))
                stepPlan.attributes.append((k, try input(b.id, "value", b.param("value"), as: .color, in: .update)))
            case .kill: stepPlan.kills.append(try input(b.id, "when", b.param("when"), as: .bool, in: .update))
            case .trigger: stepPlan.triggers.append(try input(b.id, "when", b.param("when"), as: .bool, in: .update))
            default: break
            }
        }
        if !stepPlan.isEmpty { hooks.insert(.step) }
        // Output: a size or colour the fixed emitter's lerp and three keys aren't.
        if let b = em.first(.size) {
            if wired(b.id, "size") {
                outputPlan.size = try input(b.id, "size", b.param("size"), as: .float, in: .output)
            } else if VFXLowering.linearSize(b.param("size").curve) == nil {
                let k = curveSlot("\(b.id).size", b.param("size").curve)
                outputPlan.size = VFXExpr(type: .float, metal: "vfxCurve(P + \(k), x)") { env in
                    SIMD4(repeating: VFXProgram.curve(env.params, k, env.share))
                }
            }
        }
        if let b = em.first(.color) {
            if wired(b.id, "color") {
                outputPlan.color = try input(b.id, "color", b.param("color"), as: .color, in: .output)
            } else if b.param("color").gradient.threeKeys == nil {
                let k = gradientSlot("\(b.id).color", b.param("color").gradient)
                outputPlan.color = VFXExpr(type: .color, metal: "vfxGradient(P + \(k), x)") { env in
                    VFXProgram.gradient(env.params, k, env.share)
                }
            }
        }
        if outputPlan.size != nil || outputPlan.color != nil { hooks.insert(.output) }
        guard !hooks.isEmpty else { return nil }
        let metal = VFXCodegen.functions(number: number, name: "\(effect.name)/\(em.name)", birth: initPlan, step: stepPlan,
                                         output: outputPlan, hooks: hooks)
        return VFXProgram(number: number, hooks: hooks, metal: metal, params: params, slots: slots, rate: rate,
                          attributes: attributes, initPlan: initPlan, stepPlan: stepPlan, outputPlan: outputPlan)
    }
}

enum VFXCodegen {
    /// Program `number`'s functions: vfxSpawnN, vfxStepN, vfxOutputN (those its hooks have).
    static func functions(number n: Int, name: String, birth: VFXInitPlan, step: VFXStepPlan, output: VFXOutputPlan,
                          hooks: VFXProgram.Hooks) -> String {
        var s = "// \(name.replacingOccurrences(of: "\n", with: " ")) (VFXProgram \(n))\n"
        if hooks.contains(.spawn) {
            s += """
            inline Particle vfxSpawn\(n)(ParticleEmitter e, uint emitter, uint seed, uint spawn, float3 at, float3 parentVelocity,
                                      constant ParticleStep& s, device const float4* P, device float4* A,
                                      device const ParticleFieldInfo* fields, device const float4* samples) {
                float3 offset, v;
                float life, pre;
                particleBirth(e, seed, spawn, parentVelocity, s.dt, offset, v, life, pre);

            """
            for (op, e) in birth.ops {
                switch op {
                case .lifetime: s += "    life = clamp(\(e.metal), 1e-4f, e.life.y);\n"
                case .position: s += "    offset = \(e.metal);\n"
                case .velocity: s += "    v = \(e.metal);\n"
                case .attribute(let k): s += "    A[\(k)] = \(e.metal);\n"
                }
            }
            s += """
                Particle p;
                p.position = float4(at + offset + v * pre, pre);
                p.velocity = float4(v, life);
                p.info = uint4(spawn, seed, emitter, PARTICLE_ALIVE);
                return p;
            }

            """
        }
        if hooks.contains(.step) {
            let g = step.gravity?.metal ?? "e.forces.x", c = step.curl?.metal ?? "e.forces.w", f = step.field?.metal ?? "e.field.y"
            let sw = step.swirl?.metal ?? "e.noise.z", pl = step.attraction?.metal ?? "e.noise.w"
            let d = step.drag?.metal ?? "e.forces.y", w = step.wind?.metal ?? "e.forces.z"
            s += """
            inline bool vfxStep\(n)(thread Particle& p, uint slot, ParticleEmitter e, device const ParticleCollider* colliders,
                                    constant ParticleStep& s, device const ParticleFieldInfo* fields, device const float4* samples,
                                    SCENE_ACCEL sc, thread const SceneData& sd, device const SDFScene& sdf, thread bool& event,
                                    device const float4* P, device float4* A) {
                uint flags = e.ids.w;
                float age = p.position.w + s.dt;
                if (age >= p.velocity.w) { event = (flags & PARTICLE_EVENTS_ON_DEATH) != 0; return false; }
                float3 x = p.position.xyz, v = p.velocity.xyz;
                float3 a = float3(0.0f, -s.gravity * \(g), 0.0f);
                float curl = \(c);
                if (curl != 0.0f) {
                    if (e.field.w >= 0.0f) {
                        float3 q = x * e.noise.x + float3(0.0f, s.wind.w * e.noise.y, 0.0f);
                        a += particleField(fields[uint(e.field.w)], samples, q) * (e.noise.x * curl);
                    } else {
                        a += particleCurl(x, e.noise.x, s.wind.w * e.noise.y) * curl;
                    }
                }
                if (e.field.x >= 0.0f && e.field.z == 0.0f) a += particleField(fields[uint(e.field.x)], samples, x) * \(f);
                float swirl = \(sw), pull = \(pl);
                if (swirl != 0.0f || pull != 0.0f) {
                    float3 r = x - e.attractor.xyz, axis = e.axis.xyz;
                    float3 rp = r - axis * dot(r, axis);
                    float lp = length(rp), lr = length(r);
                    if (lp > 1e-4f) a += cross(axis, rp) * (swirl / lp);
                    if (lr > 1e-4f) a -= r * (pull / lr);
                }

            """
            for force in step.forces { s += "    a += \(force.metal);\n" }
            s += """
                v += a * s.dt;
                float drag = \(d);
                if (drag > 0.0f) {
                    float3 air = s.wind.xyz * \(w);
                    v = air + (v - air) * exp(-drag * s.dt);
                }
                if (e.field.x >= 0.0f && e.field.z != 0.0f) {
                    float3 air = particleField(fields[uint(e.field.x)], samples, x);
                    v = air + (v - air) * exp(-\(f) * s.dt);
                }

            """
            for velocity in step.velocities { s += "    v = \(velocity.metal);\n" }
            s += """
                float3 from = x;
                x += v * s.dt;
                float impact = 0.0f;
                if ((flags & PARTICLE_SCENE_COLLISIONS) != 0u && (s.parity & PARTICLE_STEP_SCENE) != 0u) {
                    uint self = e.ids3.x == PARTICLE_NONE ? PARTICLE_NONE : e.ids3.x + (slot - e.ids.x);
                    impact = particleCollideScene(from, x, v, e.attractor.w, e.lock.w, e.extra.x, self, sc, sd);
                }
                for (uint i = 0; i < s.colliders; ++i) {
                    if (((e.ids2.y >> i) & 1u) == 0u) continue;
                    ParticleCollider c = colliders[i];
                    if (c.b.w == 3.0f) {
                        if ((s.parity & PARTICLE_STEP_SCENE) != 0u) impact = max(impact, particleCollideShape(c, x, v, e.attractor.w, e.lock.w, e.extra.x, sd, sdf));
                        continue;
                    }
                    impact = max(impact, particleCollide(c, x, v, e.attractor.w, e.lock.w, e.extra.x));
                }
                p.position = float4(x, age);
                p.velocity = float4(v, p.velocity.w);

            """
            for (k, value) in step.attributes { s += "    A[\(k)] = \(value.metal);\n" }
            s += """
                bool hit = impact > 0.3f;
                if (hit && (flags & PARTICLE_KILL_ON_COLLISION) != 0) {
                    event = (flags & (PARTICLE_EVENTS_ON_COLLISION | PARTICLE_EVENTS_ON_DEATH)) != 0;
                    return false;
                }
                event = hit && (flags & PARTICLE_EVENTS_ON_COLLISION) != 0;

            """
            for kill in step.kills { s += "    if (\(kill.metal)) { event = (flags & PARTICLE_EVENTS_ON_DEATH) != 0; return false; }\n" }
            for trigger in step.triggers { s += "    if (\(trigger.metal)) event = true;\n" }
            s += "    return true;\n}\n\n"
        }
        if hooks.contains(.output) {
            s += """
            inline void vfxOutput\(n)(Particle q, float x, constant ParticleStep& s, ParticleEmitter e, thread float& size,
                                      thread float4& color, device const float4* P, device const float4* A) {

            """
            if let size = output.size { s += "    size = \(size.metal) * (1.0f - e.size.z * particleRandom(q.info.y, 1u));\n" }
            if let color = output.color { s += "    color = \(color.metal);\n" }
            s += "}\n\n"
        }
        return s
    }

    /// The whole of what the VFX library adds to the kernels: every program's functions and the dispatchers
    /// (Shaders/ParticleSim.metal declares them). Without programs, dispatchers that do the fixed emitter's.
    static func source(_ programs: [VFXProgram]) -> String {
        var s = "// ---------------------------------------------------------------------------------------------\n"
        s += "// Generated (VFXCodegen): the effects' programs\n"
        s += "// ---------------------------------------------------------------------------------------------\n\n"
        for p in programs { s += p.metal }
        func cases(_ hook: VFXProgram.Hooks, _ call: (Int) -> String) -> String {
            programs.filter { $0.hooks.contains(hook) }.map { "    case \($0.number)u: \(call($0.number))\n" }.joined()
        }
        s += """
        Particle vfxSpawn(uint program, ParticleEmitter e, uint emitter, uint seed, uint spawn, float3 at, float3 parentVelocity,
                          constant ParticleStep& s, device const float4* P, device float4* A,
                          device const ParticleFieldInfo* fields, device const float4* samples) {
            switch (program) {
        \(cases(.spawn) { "return vfxSpawn\($0)(e, emitter, seed, spawn, at, parentVelocity, s, P, A, fields, samples);" })    default: return particleSpawn(e, emitter, seed, spawn, at, parentVelocity, s.dt);
            }
        }

        bool vfxStep(uint program, thread Particle& p, uint slot, ParticleEmitter e, device const ParticleCollider* colliders,
                     constant ParticleStep& s, device const ParticleFieldInfo* fields, device const float4* samples,
                     SCENE_ACCEL sc, thread const SceneData& sd, device const SDFScene& sdf, thread bool& event,
                     device const float4* P, device float4* A) {
            switch (program) {
        \(cases(.step) { "return vfxStep\($0)(p, slot, e, colliders, s, fields, samples, sc, sd, sdf, event, P, A);" })    default: return particleStep(p, slot, e, colliders, s, fields, samples, sc, sd, sdf, event);
            }
        }

        void vfxOutput(uint program, Particle q, float x, constant ParticleStep& s, ParticleEmitter e, thread float& size,
                       thread float4& color, device const float4* P, device const float4* A) {
            switch (program) {
        \(cases(.output) { "vfxOutput\($0)(q, x, s, e, size, color, P, A); return;" })    default: return;
            }
        }

        """
        return s
    }
}

extension VFXProgramBuilder {
    /// Changes the float4 at slot `k`.
    func adjust(_ k: Int, _ change: (inout SIMD4<Float>) -> Void) { change(&params[k]) }
}
