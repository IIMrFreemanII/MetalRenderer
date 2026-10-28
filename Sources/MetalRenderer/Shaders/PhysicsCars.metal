// Cars on the GPU (CarsGPU.swift): the node-beam cars of Physics+Cars.swift, CarBeams.swift, CarDrivetrain.swift,
// CarTires.swift and CarDamage.swift, a threadgroup a car. The CPU's car runs its stages one after another on a core;
// here a car's threadgroup runs a whole group of substeps in one dispatch, its beams a colour at a time between
// threadgroup barriers (Gauss-Seidel still: no two beams of a colour share a node), the cars side by side on the GPU's
// cores. Its wheels are its own: the world's bodies' stages pass them by (a kinematic body of no mass to the world:
// what it meets is pushed by a wheel that isn't pushed back), the car's kernel moves them.
//
// Nothing is summed in an order that changes from run to run: what many threads add up (the hull's middles pushed out
// of the ground) is added in fixed point, an integer's sum in any order the same; so a replay drives the same.

// MARK: - Types (CarTypes.swift; CarsGPU.swift's GPU twins)

struct PhysicsCarBeam {        // CarBeam
    uint2 nodes;
    float rest, compliance, damping, yield, load;
    uint  info;                // kind in the low 7 bits, broken, zone << 8, hull, corner, attach, part << 24
};
static_assert(sizeof(PhysicsCarBeam) == 32, "PhysicsCarBeam: CarBeam");

struct PhysicsCarLimit {       // CarBeamLimit
    float rest0, strength, strainLimit, hardening, steer, bend;
    float2 pad;
};
static_assert(sizeof(PhysicsCarLimit) == 32, "PhysicsCarLimit: CarBeamLimit");

struct PhysicsCarWheel {       // CarWheel
    int    body;
    uint   hubIn, hubOut, arm, flags;
    int    tie;
    uint2  pad0;
    float3 axle;
    float  hubOffset, radius, width, brake, spin, load;
    float2 slip;
    float  over, axleKnock, knockPeak, inverseMass;
    int    links[8];
};
static_assert(sizeof(PhysicsCarWheel) == 128, "PhysicsCarWheel: CarWheel");

struct PhysicsCarPart {        // CarPart
    int   firstNode, nodeCount;
    float inverseMass;
    uint  kind, flags;
    float still;
    int   holding, attachments;
};
static_assert(sizeof(PhysicsCarPart) == 32, "PhysicsCarPart: CarPart");

struct PhysicsCarPane {        // CarPane
    int   firstFrame, frameCount, part;
    uchar lamp, broken;
    uchar2 pad;
    uint4 corners;
};
static_assert(sizeof(PhysicsCarPane) == 32, "PhysicsCarPane: CarPane");

struct PhysicsCar {            // GPUCar (CarState's)
    float4 lo;                 // its box this step; w = its mass
    float4 hi;
    float4 momentum;           // its nodes' and wheels' as the step began (PhysicsWorld.carsGiveWay)
    float4 input;              // accelerate, decelerate, steer, handbrake (CarInput)
    float4 lap;
    float4 controls;           // throttle, brake, handbrake, steer: as the car has them (ramped)
    int  firstNode, nodeCount, ringNodes, firstBeam;
    int  beamCount, firstCorner, firstColour, colourCount;
    int  cornerColour, cornerColours, firstWheel, wheelCount;
    int  firstReaction, reactionCount;
    uint frame0, frame1;
    uint frame2;
    int  firstPart, partCount, firstPane;
    int  paneCount, firstRadiator, radiatorCount, firstTriangle;
    int  triangleCount, candidateCount;
    uint flags;                // PHYS_CAR_MANUAL...
    int  gear;
    float engine, shifting, clutch, sinceShift;
    float still, frontCrush, coolant, heat;
    float engineDamage;
    int  bent, broken, partsOff;
    int  wheelsOff, panesBroken, sinceSmoke, eventCount;
    int  hitCount;
    uint statics;              // its candidates' statics (the bodies after them)
    uint pad1, pad2;
};
static_assert(sizeof(PhysicsCar) == 288, "PhysicsCar: GPUCar");
constant uint PHYS_CAR_MANUAL = 1u, PHYS_CAR_AUTOPILOT = 2u, PHYS_CAR_RUNNING = 4u, PHYS_CAR_AWAKE = 8u, PHYS_CAR_ASLEEP = 16u;
constant uint PHYS_CAR_PAIRED = 32u;   // in a pair this step (physicsCarPairsKernel): a substep a dispatch, met after each

struct PhysicsCarTune {        // GPUCarTune (CarTune's)
    float4 rpm[2], torque[2], gears[2];
    int   gearCount;
    float reverse, finalDrive, idle, limiter, engineInertia, clutchTorque, limitedSlip, handbrake, steer, steerRate,
          dragArea, grip, tyreStiffness, tyreDamping, wheelMass;
    uint  assists;
    uint  pad[3];
};
static_assert(sizeof(PhysicsCarTune) == 176, "PhysicsCarTune: GPUCarTune");

struct PhysicsCarTelemetry {   // GPUCarTelemetry (CarTelemetry's)
    float4 position;           // w = speed (m/s)
    float4 centre;             // w = rpm
    float4 forward;            // w = throttle
    float4 up;                 // w = brake
    float steer;
    int   gear, bent, broken;
    float frontCrush, coolant, heat, engineDamage;
    uint  flags;               // PHYS_CAR_RUNNING, PHYS_CAR_ASLEEP
    int   partsOff, wheelsOff, panesBroken;
};
static_assert(sizeof(PhysicsCarTelemetry) == 112, "PhysicsCarTelemetry: GPUCarTelemetry");

// A car's step-wide numbers (CarsGPU.Header): x = the steps run (the clock), y = the commands this frame's steps have.
struct PhysicsCarClock { uint4 counts; };

constant uint PHYS_CAR = 8u;                 // PhysicsParticle.info.y: a car's node (PhysicsWorld.carBit)
constant uint PHYS_WHEEL = 128u;             // PhysicsBody.info.y: a car's wheel (PhysicsWorld.wheelBit)
constant uint PHYS_CAR_COMMAND = 7u;         // PhysicsWorld.FractureCommand.car
constant uint PHYS_CAR_SHIFT_UP = 1u << 8, PHYS_CAR_SHIFT_DOWN = 2u << 8, PHYS_CAR_CMD_MANUAL = 4u << 8, PHYS_CAR_CMD_AUTOPILOT = 8u << 8;
constant uint PHYS_CAR_CANDIDATES = 512;     // CarsGPU.maxCandidates
constant uint PHYS_CAR_EVENTS = 16;          // CarSystem.maxEvents
// CarBeam's bits and kinds (CarBeamKind), the arm zone (CarBeamZone.arm).
constant uint PHYS_BEAM_BROKEN = 1u << 7, PHYS_BEAM_HULL = 1u << 16, PHYS_BEAM_CORNER = 1u << 17, PHYS_BEAM_ATTACH = 1u << 18;
constant uint PHYS_BEAM_PLASTIC = 0, PHYS_BEAM_COMPRESSION = 2, PHYS_BEAM_TENSION = 3, PHYS_BEAM_STEER = 5, PHYS_BEAM_SUPPORT = 6;
constant uint PHYS_ZONE_ARM = 9;
// CarWheel's flags, CarPart's.
constant uint PHYS_WHEEL_DRIVEN = 1, PHYS_WHEEL_HANDBRAKED = 4, PHYS_WHEEL_FRONT = 8, PHYS_WHEEL_OFF = 16;
constant uint PHYS_PART_OFF = 1, PHYS_PART_FROZEN = 2;
// CarSolver's and PhysicsWorld's numbers for cars.
constant float PHYS_CAR_FLOW = 0.008f, PHYS_CAR_LOAD_AVERAGE = 0.25f;
constant uint  PHYS_CORNER_PASSES = 2, PHYS_AXLE_PASSES = 2;
constant float PHYS_AXLE_COMPLIANCE = 1e-9f, PHYS_AXLE_STRENGTH = 32000.0f, PHYS_CAR_TOP_SPEED = 90.0f, PHYS_AIR_DENSITY = 1.2f;
constant float PHYS_TYRE_PEAK_RATIO = 0.1f, PHYS_TYRE_PEAK_ANGLE = 0.12f, PHYS_TYRE_SHAPE_ALONG = 1.5f, PHYS_TYRE_SHAPE_ACROSS = 1.35f;
constant float PHYS_TYRE_ROLLING = 0.012f, PHYS_TYRE_DEPTH = 0.07f;   // CarBlueprint.tyreDepth: the rim's under the tyre's
constant float PHYS_CAR_NODE_RADIUS = 0.06f;                          // CarBlueprint.radius
constant float PHYS_SCRAPE_SPEED = 3.0f, PHYS_SCRAPE_LENGTH = 0.4f, PHYS_DIRT_LENGTH = 3.0f, PHYS_CRUSH_STRAIN = 0.08f;
constant float PHYS_FREEZE_AFTER = 1.0f, PHYS_STILL_SPEED = 0.15f, PHYS_CAR_SLEEP_AFTER = 1.0f;
constant float PHYS_COOLANT_LOSS = 0.05f, PHYS_HEATING = 0.03f, PHYS_COOLING = 0.05f;
constant int   PHYS_SMOKE_EVERY = 6, PHYS_TORN_BELOW = 2, PHYS_LINKS_LOST = 3;
constant uint  PHYS_MOUNT_CRUSH = 191;
constant float PHYS_RADIATOR_CRUSH = 0.08f, PHYS_RADIATOR_SPAN = 0.25f, PHYS_BLOCK_CRUSH = 0.5f, PHYS_BLOCK_SPAN = 0.3f;
constant float PHYS_GLASS_STRAIN = 0.008f, PHYS_LAMP_STRAIN = 0.03f;
constant uint  PHYS_EVENT_GLASS = 8, PHYS_EVENT_STEAM = 9, PHYS_EVENT_SMOKE = 10, PHYS_EVENT_DEBRIS = 11;   // CarEvent.slot
// The hull's middles' pushes summed in fixed point (an int's step: 0.1 µm).
constant float PHYS_CAR_FIXED = 1e7f;
// What the cars do to a body over a group of substeps, summed in fixed point (CarsGPU.bodyWords ints a body): their
// nodes' pushes (mass-weighted corrections: kg m) and their turns, how many; their tyres' kicks (N s) and turns, how
// many; over the step, their knocks on a piece (N s), where (m N s) and which way (N s), and which cars knocked it (a
// bit a car).
constant uint PHYS_BODY_WORDS = 24;
constant uint PHYS_CAR_CARRIED = 32;   // the bodies a car carries its own pushes on through a group (physCarNode)
constant uint PHYS_ACC_PUSH = 0, PHYS_ACC_PUSH_TWIST = 3, PHYS_ACC_PUSHES = 6, PHYS_ACC_KICK = 8, PHYS_ACC_KICK_TWIST = 11, PHYS_ACC_KICKS = 14;
constant uint PHYS_ACC_KNOCK = 16, PHYS_ACC_KNOCK_POINT = 17, PHYS_ACC_KNOCK_PUSH = 20, PHYS_ACC_HITS = 23;
constant float PHYS_PUSH_FIXED = 1e6f, PHYS_KICK_FIXED = 1e5f, PHYS_KNOCK_FIXED = 1e4f, PHYS_POINT_FIXED = 1e3f;

inline void physAddFixed(device atomic_int* a, float3 v, float scale) {
    int3 f = int3(round(v * scale));
    atomic_fetch_add_explicit(a, f.x, memory_order_relaxed);
    atomic_fetch_add_explicit(a + 1, f.y, memory_order_relaxed);
    atomic_fetch_add_explicit(a + 2, f.z, memory_order_relaxed);
}
inline float3 physFixed3(device atomic_int* a, float scale) {
    return float3(atomic_load_explicit(a, memory_order_relaxed), atomic_load_explicit(a + 1, memory_order_relaxed),
                  atomic_load_explicit(a + 2, memory_order_relaxed)) / scale;
}

// MARK: - Helpers

inline uint physBeamKind(uint info) { return info & 0x7Fu; }
inline uint physBeamZone(uint info) { return (info >> 8) & 0xFFu; }
inline int  physBeamPart(uint info) { return int(info >> 24); }

// Wheel w's body as its car moves it: its mass back (to the world it has none: CarsGPU.prepare), not kinematic.
inline PhysicsBody physWheelBody(device const PhysicsBody* bodies, PhysicsCarWheel w) {
    PhysicsBody o = bodies[w.body];
    o.position.w = w.inverseMass;
    o.info.y &= ~PHYS_KINEMATIC;
    return o;
}
// ...and back into the world's bodies, a kinematic body of no mass again.
inline void physStoreWheel(device PhysicsBody* bodies, PhysicsCarWheel w, PhysicsBody o) {
    o.position.w = 0.0f;
    o.info.y |= PHYS_KINEMATIC;
    bodies[w.body] = o;
}

// A car's node as its substeps' kernel keeps it (in threadgroup memory: the particle's position, velocity and prevPosition).
struct PhysCarNode { float4 position, velocity, prevPosition; };
constant int PHYS_CAR_NODES = 432;   // CarsGPU.maxNodes
constant int PHYS_CAR_CORNERS = 288; // CarsGPU.maxCorners: a car's corners' beams, at most
// The substeps' scratch in threadgroup memory: the corners' beams and their lambdas, then (once they are done) the hull's
// middles' pushes (four ints a node).
constant constexpr int PHYS_CAR_SCRATCH = 432 * 16 > 288 * 36 ? 432 * 16 : 288 * 36;   // (max of the two)

struct PhysCarFrame { float3 centre, forward, up, left, velocity; };

// PhysicsWorld.carFrame, from nodes `q` (a node i at q[i - base]).
template <typename Q> inline PhysCarFrame physCarFrame(PhysicsCar s, Q q, int base) {
    float3 rear = q[int(s.frame0) - base].position.xyz, front = q[int(s.frame1) - base].position.xyz, side = q[int(s.frame2) - base].position.xyz;
    PhysCarFrame f;
    f.centre = (rear + front) * 0.5f;
    f.forward = physDirection(front - rear);
    f.up = physDirection(cross(f.forward, side - f.centre));
    f.left = cross(f.up, f.forward);
    f.velocity = (q[int(s.frame0) - base].velocity.xyz + q[int(s.frame1) - base].velocity.xyz) * 0.5f;
    return f;
}

inline float physApproach(float x, float target, float step) { return x < target ? min(x + step, target) : max(x - step, target); }

inline float physCarRatio(PhysicsCarTune t, int gear) {
    float4 lo = t.gears[0], hi = t.gears[1];
    float g = gear <= 1 ? lo.x : gear == 2 ? lo.y : gear == 3 ? lo.z : gear == 4 ? lo.w : gear == 5 ? hi.x : gear == 6 ? hi.y : gear == 7 ? hi.z : hi.w;
    return gear > 0 ? g * t.finalDrive : gear < 0 ? -t.reverse * t.finalDrive : 0.0f;
}

// CarTune.torque(at:). (Its loop unrolled: the curve's points stay in registers.)
inline float physCarTorque(PhysicsCarTune t, float w) {
    float r = w * 30.0f / M_PI_F;
    float rpm[8] = {t.rpm[0].x, t.rpm[0].y, t.rpm[0].z, t.rpm[0].w, t.rpm[1].x, t.rpm[1].y, t.rpm[1].z, t.rpm[1].w};
    float torque[8] = {t.torque[0].x, t.torque[0].y, t.torque[0].z, t.torque[0].w, t.torque[1].x, t.torque[1].y, t.torque[1].z, t.torque[1].w};
    if (r <= rpm[0]) return torque[0] * max(r, 0.0f) / rpm[0];
    float out = 0.0f;
    bool found = false;
    #pragma unroll
    for (int k = 1; k < 8; ++k) {
        if (!found && r <= rpm[k]) {
            out = torque[k - 1] + (torque[k] - torque[k - 1]) * (r - rpm[k - 1]) / (rpm[k] - rpm[k - 1]);
            found = true;
        }
    }
    return out;
}

inline bool physHasInput(PhysicsCar s) {
    return any(s.input != float4(0.0f)) || any(s.lap != float4(0.0f)) || (s.flags & (PHYS_CAR_MANUAL | PHYS_CAR_AUTOPILOT)) != 0;
}

// CarSolver.couple: an angular impulse l on the engine's nodes, as velocity changes about their middle.
inline void physCouple(float3 l, threadgroup PhysCarNode* q, int base, device const uint* reactions, int first, int count) {
    if (count <= 1 || length_squared(l) <= 0.0f) return;
    float3 centre = float3(0.0f);
    for (int k = first; k < first + count; ++k) centre += q[int(reactions[k]) - base].position.xyz;
    centre /= float(count);
    float3 axis = normalize(l);
    float spread = 0.0f;
    for (int k = first; k < first + count; ++k) {
        float3 r = q[int(reactions[k]) - base].position.xyz - centre;
        spread += length_squared(r) - dot(r, axis) * dot(r, axis);
    }
    if (spread <= 1e-6f) return;
    for (int k = first; k < first + count; ++k) {
        int i = int(reactions[k]) - base;
        float3 r = q[i].position.xyz - centre;
        q[i].velocity.xyz += cross(l, r) / spread * q[i].prevPosition.w;
    }
}

// CarSolver.knuckleCouple: an angular impulse on a wheel's knuckle, its steering arm one way, its hubs the other.
inline void physKnuckleCouple(float3 l, PhysicsCarWheel w, threadgroup PhysCarNode* q, int base) {
    int arm = int(w.arm) - base, hubIn = int(w.hubIn) - base, hubOut = int(w.hubOut) - base;
    float3 middle = (q[hubIn].position.xyz + q[hubOut].position.xyz) * 0.5f;
    float3 r = q[arm].position.xyz - middle;
    float3 axis = physDirection(l);
    r -= axis * dot(r, axis);
    float r2 = length_squared(r);
    if (r2 <= 1e-6f) return;
    float3 push = cross(l, r) / r2;
    q[arm].velocity.xyz += push * q[arm].prevPosition.w;
    q[hubIn].velocity.xyz -= push * (0.5f * q[hubIn].prevPosition.w);
    q[hubOut].velocity.xyz -= push * (0.5f * q[hubOut].prevPosition.w);
}

// CarSolver.hubCouple: an angular impulse across a wheel's axle, as a couple on its two hubs.
inline void physHubCouple(float3 l, PhysicsCarWheel w, threadgroup PhysCarNode* q, int base) {
    int hubIn = int(w.hubIn) - base, hubOut = int(w.hubOut) - base;
    float3 apart = q[hubOut].position.xyz - q[hubIn].position.xyz;
    float a2 = length_squared(apart);
    if (a2 <= 1e-6f) return;
    float3 push = cross(l, apart) / a2;
    q[hubOut].velocity.xyz += push * q[hubOut].prevPosition.w;
    q[hubIn].velocity.xyz -= push * q[hubIn].prevPosition.w;
}

// CarSolver.autopilot.
inline void physAutopilot(thread PhysicsCar& s, float3 centre, float3 forward, float speed) {
    float4 lap = s.lap;
    float2 r = float2(centre.x - lap.x, centre.z - lap.y);
    float distance = max(length(r), 1e-3f);
    float2 radial = r / distance, tangent = float2(-radial.y, radial.x);
    float2 want = normalize(tangent - radial * clamp((distance - lap.z) * 0.15f, -0.6f, 0.6f));
    float2 ahead = float2(forward.x, forward.z);
    if (length(ahead) <= 1e-3f) return;
    float2 heading = normalize(ahead);
    float error = atan2(heading.x * want.y - heading.y * want.x, dot(heading, want));
    s.input.z = clamp(-error * 2.0f, -1.0f, 1.0f);
    float e = lap.w - speed;
    s.input.x = clamp(e * 0.5f, 0.0f, 1.0f);
    s.input.y = clamp(-e * 0.3f, 0.0f, 1.0f);
}

// A static candidate of a car (PhysicsWorld.staticBit) near x: its shape's distance at x.
inline bool physNearStatic(device const float4* bounds, uint st, float3 x, float r) {
    float3 lo = bounds[2 * st].xyz, hi = bounds[2 * st + 1].xyz;
    return all(x >= lo - r) && all(x <= hi + r);
}

// MARK: - The drivetrain (CarSolver.carForces, before the tyres): one thread a car

// A wheel as the drivetrain reads it (its wheel's thread loads it, side by side with the others'), and the spin changes
// it leaves for it: all of them, and the brake's (whose reaction turns the knuckle).
struct PhysWheelNow {
    float3 axis;
    float spin, inverse, load, over, radius, brake;
    uint  flags;
    float dw, brakeDw;
};

inline void physCarDrive(thread PhysicsCar& s, PhysicsCarTune t, threadgroup PhysWheelNow* wn, int count, threadgroup PhysCarNode* q, int base,
                         device const uint* reactions, float h, uint sub, thread float3& dragOut, thread float& turnOut) {
    PhysCarFrame f = physCarFrame(s, q, base);
    float speed = dot(f.velocity, f.forward);
    if (sub == 0 && (s.flags & PHYS_CAR_AUTOPILOT) != 0) physAutopilot(s, f.centre, f.forward, speed);
    float4 input = s.input;   // accelerate, decelerate, steer, handbrake
    if ((s.flags & PHYS_CAR_MANUAL) == 0) {
        if (s.gear >= 0 && input.y > 0.1f && input.x < 0.1f && speed < 0.5f) s.gear = -1;
        else if (s.gear <= 0 && input.x > 0.1f && input.y < 0.1f && speed > -0.5f) s.gear = 1;
    }
    bool reversing = s.gear < 0;
    float throttleTarget = reversing ? input.y : input.x, brakeTarget = reversing ? input.x : input.y;
    s.controls.x = physApproach(s.controls.x, throttleTarget, (throttleTarget > s.controls.x ? 6.0f : 10.0f) * h);
    s.controls.y = physApproach(s.controls.y, brakeTarget, 8.0f * h);
    s.controls.z = physApproach(s.controls.z, input.w, 10.0f * h);
    s.controls.w = physApproach(s.controls.w, input.z * t.steer / (1.0f + abs(speed) / 20.0f), t.steerRate * h);
    turnOut = sin(s.controls.w);

    // (The wheels' spins and inverse inertias in threadgroup memory, wn: a thread's array indexed at run time would
    // live in its stack, in device memory.)
    float driven = 0.0f, drivenInverse = 0.0f, meanSpin = 0.0f;
    for (int k = 0; k < count; ++k) {
        if ((wn[k].flags & PHYS_WHEEL_DRIVEN) != 0) {
            driven += 1.0f;
            drivenInverse += wn[k].inverse;
            meanSpin += wn[k].spin;
        }
    }
    meanSpin /= max(driven, 1.0f);

    // Traction control: the throttle eased off while the driven wheels spin faster than the car goes over the ground.
    float spinning = 0.0f;
    if (t.assists != 0 && driven > 0.0f) {
        float over = 0.0f, touching = 0.0f;
        for (int k = 0; k < count; ++k) {
            if ((wn[k].flags & PHYS_WHEEL_DRIVEN) != 0 && wn[k].load > 0.0f) { over += abs(wn[k].over); touching += 1.0f; }
        }
        float ground = touching > 0.0f ? over / touching : abs(speed), wheel = abs(meanSpin) * wn[0].radius;
        spinning = clamp((wheel - ground * (1.0f + PHYS_TYRE_PEAK_RATIO) - 0.3f) / 1.0f, 0.0f, 1.0f);
    }
    // The engine: its power cut by its damage and its heat past half; a seized one stopped.
    bool running = (s.flags & PHYS_CAR_RUNNING) != 0;
    if (running) {
        float throttle = s.controls.x * (1.0f - 0.95f * spinning);
        if (s.engine < t.idle) throttle = max(throttle, min((t.idle - s.engine) / (0.2f * t.idle), 1.0f) * 0.3f);
        if (s.engine > t.limiter) throttle = 0.0f;
        float power = (1.0f - s.engineDamage) * (1.0f - 1.2f * max(s.heat - 0.5f, 0.0f));
        float torque = throttle * power * physCarTorque(t, s.engine) - (15.0f + 0.02f * s.engine) * min(s.engine / 10.0f, 1.0f);
        s.engine = max(s.engine + torque * h / t.engineInertia, 0.0f);
    } else {
        s.engine = 0.0f;
    }
    // The gearbox: automatic shifts, up near the limiter, down near idle, not back at once.
    s.sinceShift += h;
    if (s.shifting > 0.0f) {
        s.shifting -= h;
    } else if ((s.flags & PHYS_CAR_MANUAL) == 0 && s.gear > 0 && s.sinceShift > 0.8f) {
        float gearbox = physCarRatio(t, s.gear) * meanSpin;
        if (gearbox > 0.92f * t.limiter && s.gear < t.gearCount && s.controls.x > 0.3f) {
            s.gear += 1; s.shifting = 0.2f; s.sinceShift = 0.0f;
        } else if (s.gear > 1 && gearbox < 2.2f * t.idle && physCarRatio(t, s.gear - 1) * meanSpin < 0.75f * t.limiter) {
            s.gear -= 1; s.shifting = 0.15f; s.sinceShift = 0.0f;
        }
    }
    // The clutch: slipping at a launch, in while the gearbox turns above idle.
    float g = physCarRatio(t, s.gear), engage = 0.0f;
    if (g != 0.0f && s.shifting <= 0.0f && driven > 0.0f && running) {
        float launch = s.controls.x > 0.05f ? clamp((s.engine - t.idle) / (1.2f * t.idle), 0.0f, 1.0f) : 0.0f;
        float rolling = clamp((abs(g * meanSpin) - 0.9f * t.idle) / (0.4f * t.idle), 0.0f, 1.0f);
        engage = max(launch, rolling);
    }
    s.clutch = engage;
    float given = 0.0f;
    if (engage > 0.0f && drivenInverse > 0.0f) {
        float gearbox = g * g / (driven * driven) * drivenInverse;
        float most = t.clutchTorque * engage * h;
        float j = clamp((s.engine - g * meanSpin) / (1.0f / t.engineInertia + gearbox), -most, most);
        s.engine -= j / t.engineInertia;
        given = j * g / driven;
    }
    // (A wheel's spin changed by dw takes the angular impulse axis x dw / its inverse inertia about it: spinWheel.)
    float3 reaction = float3(0.0f);
    if (given != 0.0f) {
        for (int k = 0; k < count; ++k) {
            if ((wn[k].flags & PHYS_WHEEL_DRIVEN) == 0) continue;
            float dw = given * wn[k].inverse;
            wn[k].spin += dw;
            wn[k].dw += dw;
            if (wn[k].inverse > 0.0f) reaction += wn[k].axis * (dw / wn[k].inverse);
        }
        // A limited-slip differential: a driven pair's spins together, as far as its locking allows.
        if (t.limitedSlip > 0.0f) {
            for (int pair = 0; pair < count / 2; ++pair) {
                int k0 = 2 * pair, k1 = k0 + 1;
                if ((wn[k0].flags & wn[k1].flags & PHYS_WHEEL_DRIVEN) == 0 || !(wn[k0].inverse + wn[k1].inverse > 0.0f)) continue;
                float most = (100.0f + t.limitedSlip * abs(given) / h) * h;
                float j = clamp((wn[k0].spin - wn[k1].spin) / (wn[k0].inverse + wn[k1].inverse), -most, most);
                wn[k0].spin -= j * wn[k0].inverse;
                wn[k1].spin += j * wn[k1].inverse;
                wn[k0].dw -= j * wn[k0].inverse;
                wn[k1].dw += j * wn[k1].inverse;
            }
        }
        physCouple(-reaction, q, base, reactions, s.firstReaction, s.reactionCount);
    }
    // The brakes (a locked wheel stays locked), ABS, traction control's brakes.
    for (int k = 0; k < count; ++k) {
        float pedal = wn[k].brake * s.controls.y;
        float ground = wn[k].load > 0.0f ? abs(wn[k].over) : abs(speed);
        if (t.assists != 0 && ground > 2.0f) {
            float ratio = 1.0f - abs(wn[k].spin) * wn[k].radius / ground;
            pedal *= clamp(1.0f - (ratio / PHYS_TYRE_PEAK_RATIO - 0.8f) / 0.5f, 0.15f, 1.0f);
        }
        if (t.assists != 0 && (wn[k].flags & PHYS_WHEEL_DRIVEN) != 0) {
            float excess = abs(wn[k].spin) * wn[k].radius - ground * (1.0f + PHYS_TYRE_PEAK_RATIO) - 0.2f;
            if (excess > 0.0f) pedal += min(excess * 1500.0f, wn[k].brake);
        }
        float torque = pedal + ((wn[k].flags & PHYS_WHEEL_HANDBRAKED) != 0 ? t.handbrake * s.controls.z : 0.0f);
        if (!(torque > 0.0f) || !(wn[k].inverse > 0.0f)) continue;
        float most = torque * h * wn[k].inverse;
        float dw = wn[k].spin > 0.0f ? -min(wn[k].spin, most) : min(-wn[k].spin, most);
        if (dw == 0.0f) continue;
        wn[k].spin += dw;
        wn[k].dw += dw;
        wn[k].brakeDw = dw;
    }
    // The air's drag (the nodes take it as they move).
    float v = length(f.velocity), mass = s.lo.w;
    dragOut = v > 1e-3f ? -f.velocity * (0.5f * PHYS_AIR_DENSITY * t.dragArea * v * h / mass) : float3(0.0f);
}

// MARK: - A tyre (CarSolver.tyre): one thread a wheel

inline void physCarTyre(device PhysicsCarWheel* wheels, int wk, PhysicsCarTune t, device const uint* candidates, uint firstCandidate,
                        uint candidateCount, threadgroup PhysCarNode* q, int base, device PhysicsBody* bodies, device atomic_int* acc,
                        device const PhysicsBody* statics,
                        device const float4* bounds, PhysicsShapes shapes, float h) {
    PhysicsCarWheel w = wheels[wk];
    PhysicsBody o = physWheelBody(bodies, w);
    if (!physMoves(o)) return;
    float3 centre = o.position.xyz, a = quatRotate(o.rotation, w.axle);
    float radius = w.radius;
    // The static or body nearest the wheel's centre within its reach.
    int best = -1;
    float nearest = radius + 0.05f;
    bool onBody = false;
    for (uint k = firstCandidate; k < firstCandidate + candidateCount; ++k) {
        uint code = candidates[k];
        if ((code & PHYS_STATIC) != 0) {
            uint st = code & ~PHYS_STATIC;
            if (!physNearStatic(bounds, st, centre, radius)) continue;
            PhysicsBody s = statics[st];
            float d = physDistance(shapes, s.info.x, physPose(s).toBody(centre));
            if (d < nearest) { best = int(st); nearest = d; onBody = false; }
        } else {
            PhysicsBody s = bodies[code];
            float reach = radius + s.invInertia.w;
            if (length_squared(centre - s.position.xyz) > reach * reach) continue;
            float d = physDistance(shapes, s.info.x, physPose(s).toBody(centre));
            if (d < nearest) { best = int(code); nearest = d; onBody = true; }
        }
    }
    w.load = 0.0f;
    w.slip = float2(0.0f);
    w.over = 0.0f;
    if (best < 0) { wheels[wk] = w; return; }
    PhysicsBody s = onBody ? bodies[best] : statics[best];
    PhysPose pose = physPose(s);
    uint shape = s.info.x;
    float3 n = pose.direction(physGradient(shapes, shape, pose.toBody(centre)));
    float3 down = -n + a * dot(n, a);
    float l = length(down);
    if (l <= 0.3f) { wheels[wk] = w; return; }
    down /= l;
    float3 patch = centre + down * radius, local = pose.toBody(patch);
    float depth = -physDistance(shapes, shape, local);
    if (!(depth > 0.0f)) { wheels[wk] = w; return; }
    n = pose.direction(physGradient(shapes, shape, local));
    bool groundMoves = onBody && physMoves(s);
    float3 ground = groundMoves ? s.velocity.xyz + cross(s.angular.xyz, patch - s.position.xyz) : float3(0.0f);
    float3 v = o.velocity.xyz, spinning = o.angular.xyz;
    float load = clamp(t.tyreStiffness * depth - t.tyreDamping * dot(v - ground, n), 0.0f, t.tyreStiffness * 0.15f);
    float3 lever = patch - centre;
    float3 slipping = v + cross(spinning, lever) - ground;
    float3 along = physDirection(cross(a, n)), across = physDirection(a - n * dot(a, n));
    float sx = dot(slipping, along), sy = dot(slipping, across), vx = dot(v, along);
    float grip = t.grip * min(s.velocity.w / 0.7f, 1.3f);
    float k = physTurnWeight(o, a);
    float cornerMass = 1.0f / o.position.w + 1.0f / max(q[int(w.hubIn) - base].prevPosition.w, 1e-3f)
        + 1.0f / max(q[int(w.hubOut) - base].prevPosition.w, 1e-3f);
    float acrossMass = cornerMass, alongMass = 1.0f / (1.0f / cornerMass + radius * radius * k);
    // The Magic Formula, the slips normalised by their peaks.
    float reference = max(abs(vx), 0.5f);
    float ux = sx / (PHYS_TYRE_PEAK_RATIO * reference), uy = sy / (PHYS_TYRE_PEAK_ANGLE * reference);
    float u = sqrt(ux * ux + uy * uy);
    float jx = 0.0f, jy = 0.0f;
    if (u > 1e-6f) {
        float shapeC = (PHYS_TYRE_SHAPE_ALONG * ux * ux + PHYS_TYRE_SHAPE_ACROSS * uy * uy) / (u * u);
        float shapeB = tan(M_PI_F / (2.0f * shapeC));
        float force = grip * load * sin(shapeC * atan(shapeB * u));
        jx = -force * h * ux / u;
        jy = -force * h * uy / u;
    }
    jx = clamp(jx, -abs(sx) * alongMass, abs(sx) * alongMass);
    jy = clamp(jy, -abs(sy) * acrossMass, abs(sy) * acrossMass);
    // Slow: Coulomb friction.
    float blend = clamp((abs(vx) - 1.0f) / 2.0f, 0.0f, 1.0f);
    if (blend < 1.0f) {
        float cx = -sx * alongMass, cy = -sy * acrossMass;
        float most = grip * load * h, lc = sqrt(cx * cx + cy * cy);
        if (lc > most) { cx *= most / lc; cy *= most / lc; }
        jx = cx + (jx - cx) * blend;
        jy = cy + (jy - cy) * blend;
    }
    float3 impulse = n * (load * h) + along * jx + across * jy;
    o.velocity = float4(v + impulse * o.position.w, o.velocity.w);
    float3 torque = cross(lever, impulse);
    float about = dot(torque, a);
    float spin = dot(spinning, a) + about * k;
    float roll = PHYS_TYRE_ROLLING * load * radius * h * k;
    spin -= spin > 0.0f ? min(roll, spin) : max(-roll, spin);
    o.angular = float4(spinning + a * (spin - dot(spinning, a)), o.angular.w);
    physStoreWheel(bodies, w, o);
    // (On a body: it takes the patch's impulse back, a kick: CarSolver.tyreKick.)
    if (groundMoves) {
        device atomic_int* k = acc + uint(best) * PHYS_BODY_WORDS;
        physAddFixed(k + PHYS_ACC_KICK, -impulse, PHYS_KICK_FIXED);
        physAddFixed(k + PHYS_ACC_KICK_TWIST, cross(patch - s.position.xyz, -impulse), PHYS_KICK_FIXED);
        atomic_fetch_add_explicit(k + PHYS_ACC_KICKS, 1, memory_order_relaxed);
    }
    physHubCouple(torque - a * about, w, q, base);
    w.load = load;
    w.slip = float2(sx, sy);
    w.over = dot(v - ground, along);
    w.spin = spin;
    wheels[wk] = w;
}

// MARK: - Constraints (CarBeams.swift)

// CarSolver.solveAxle: wheel wk's two hub points held to its hub nodes.
inline void physCarAxle(device PhysicsCarWheel* wheels, int wk, threadgroup PhysCarNode* q, int base, device PhysicsBody* bodies, float h) {
    PhysicsCarWheel w = wheels[wk];
    PhysicsBody o = physWheelBody(bodies, w);
    float soft = PHYS_AXLE_COMPLIANCE / (h * h);
    float3 taken = float3(0.0f);
    for (uint end = 0; end < 2; ++end) {
        int node = int(end == 0 ? w.hubIn : w.hubOut) - base;
        float3 r = quatRotate(o.rotation, w.axle * (end == 0 ? -w.hubOffset : w.hubOffset));
        float3 x = q[node].position.xyz;
        float3 d = o.position.xyz + r - x;
        float l = length(d);
        if (!(l > 1e-9f)) continue;
        float3 n = d / l;
        float wn = q[node].prevPosition.w, wb = physWeight(o, r, n);
        if (!(wn + wb > 0.0f)) continue;
        float lambda = l / (wn + wb + soft);
        taken += n * lambda;
        q[node].position.xyz = x + n * (lambda * wn);
        physShove(o, -n * lambda, r);
    }
    physStoreWheel(bodies, w, o);
    wheels[wk].axleKnock = max(w.axleKnock, length(taken.xz) / (h * h));
}

// CarSolver.flow: beam k's load this substep `force`: summed for its step, averaged, its rest flowed past its yield.
inline void physCarFlow(uint k, thread PhysicsCarBeam& beam, float force, device float* loads, device PhysicsCarLimit* limits) {
    float alpha = beam.compliance;
    loads[k] += force;
    beam.load += PHYS_CAR_LOAD_AVERAGE * (force - beam.load);
    float over = abs(beam.load) - beam.yield;
    if (over > 0.0f) {
        float flow = min(over * alpha, PHYS_CAR_FLOW), change = beam.load > 0.0f ? flow : -flow;
        beam.rest += change;
        PhysicsCarLimit limit = limits[k];
        beam.yield *= 1.0f + limit.hardening * flow / limit.rest0;
        if (physBeamKind(beam.info) == PHYS_BEAM_STEER) limits[k].bend = limit.bend + change;
    }
}

// CarSolver.solveBeam, for beam k as read (`beam`), its lambda so far `lambda0` (0 on the step's first pass).
inline void physCarBeam(uint k, PhysicsCarBeam beam, float lambda0, device PhysicsCarBeam* beams, device float* lambdas, device float* loads,
                        device PhysicsCarLimit* limits, threadgroup PhysCarNode* q, int base, float h, bool first) {
    if ((beam.info & PHYS_BEAM_BROKEN) != 0) return;
    int ia = int(beam.nodes.x) - base, ib = int(beam.nodes.y) - base;
    float4 pa = q[ia].position, pb = q[ib].position, oa = q[ia].prevPosition, ob = q[ib].prevPosition;
    float wa = oa.w, wb = ob.w;
    if (!(wa + wb > 0.0f)) return;
    float3 xa = pa.xyz, xb = pb.xyz;
    float3 d = xa - xb;
    float l = length(d);
    if (!(l > 1e-9f)) return;
    uint kind = physBeamKind(beam.info);
    if (kind == PHYS_BEAM_COMPRESSION && l >= beam.rest) return;
    if (kind == PHYS_BEAM_TENSION && l <= beam.rest) return;
    float3 n = d / l;
    float stretch = l - beam.rest;
    float alpha = beam.compliance, soft = alpha / (h * h), gamma = alpha * beam.damping / h;
    float moved = dot(n, (xa - oa.xyz) - (xb - ob.xyz));
    float lambda = (-stretch - soft * lambda0 - gamma * moved) / ((1.0f + gamma) * (wa + wb) + soft);
    lambdas[k] = lambda0 + lambda;
    q[ia].position.xyz = xa + n * (lambda * wa);
    q[ib].position.xyz = xb - n * (lambda * wb);
    if (!(kind == PHYS_BEAM_PLASTIC || kind == PHYS_BEAM_SUPPORT) || !first || physBeamZone(beam.info) == PHYS_ZONE_ARM) return;
    physCarFlow(k, beam, stretch / alpha, loads, limits);
    beams[k] = beam;
}

// ...a corner's beam again, from threadgroup memory (`beam` and its lambda there: no flow on these passes).
inline void physCarCorner(PhysicsCarBeam beam, threadgroup float& lambdaSum, threadgroup PhysCarNode* q, int base, float h) {
    if ((beam.info & PHYS_BEAM_BROKEN) != 0) return;
    int ia = int(beam.nodes.x) - base, ib = int(beam.nodes.y) - base;
    float4 pa = q[ia].position, pb = q[ib].position, oa = q[ia].prevPosition, ob = q[ib].prevPosition;
    float wa = oa.w, wb = ob.w;
    if (!(wa + wb > 0.0f)) return;
    float3 xa = pa.xyz, xb = pb.xyz;
    float3 d = xa - xb;
    float l = length(d);
    if (!(l > 1e-9f)) return;
    uint kind = physBeamKind(beam.info);
    if (kind == PHYS_BEAM_COMPRESSION && l >= beam.rest) return;
    if (kind == PHYS_BEAM_TENSION && l <= beam.rest) return;
    float3 n = d / l;
    float alpha = beam.compliance, soft = alpha / (h * h), gamma = alpha * beam.damping / h;
    float moved = dot(n, (xa - oa.xyz) - (xb - ob.xyz));
    float lambda = (-(l - beam.rest) - soft * lambdaSum - gamma * moved) / ((1.0f + gamma) * (wa + wb) + soft);
    lambdaSum += lambda;
    q[ia].position.xyz = xa + n * (lambda * wa);
    q[ib].position.xyz = xb - n * (lambda * wb);
}

// CarSolver.sliding: how far a node slid on what it touched, fast (a scrape) and at all (dirt).
inline float2 physCarSliding(float3 moved, float3 n, float h) {
    float along = length(moved - n * dot(moved, n));
    return float2(along > PHYS_SCRAPE_SPEED * h ? along : 0.0f, along);
}

// CarSolver.nodeContacts: node i (absolute; q's at i - base) pushed out of the statics and bodies among the candidates;
// a body's share of a push summed for it (`acc`: the world applies them after the group, physicsCarBodiesKernel), its
// mass as one of as many shares as it had pushes a substep the group before (`shares`: mass splitting); a piece knocked
// faster than PHYS_IMPACT_SPEED, its knock summed for its strain (and car `bit` noted: physicsCarGiveWayKernel).
//
// The world moves the bodies after the group: within it, this car sees each of its first PHYS_CAR_CARRIED bodies where
// its own pushes so far have shoved it (`carried`, its candidates' order from `firstBody`; `done` substeps of the group
// before this one), or a car would push on against a crate that hasn't moved, and stop.
inline void physCarNode(int i, threadgroup PhysCarNode* q, int base, device float2* wear, device const uint* candidates, uint first, uint count,
                        device const PhysicsBody* statics, device const float4* bounds, device const PhysicsBody* bodies,
                        device atomic_int* acc, device const float* shares, uint bit, device atomic_int* carried, uint firstBody,
                        uint done, PhysicsShapes shapes, float h) {
    PhysCarNode p = q[i - base];
    float wn = p.prevPosition.w;
    if (!(wn > 0.0f)) return;
    float r = p.position.w;
    float3 prev = p.prevPosition.xyz, x = p.position.xyz;
    float2 slid = float2(0.0f);
    for (uint k = first; k < first + count; ++k) {
        uint code = candidates[k];
        if ((code & PHYS_STATIC) != 0) {
            uint st = code & ~PHYS_STATIC;
            if (!physNearStatic(bounds, st, x, r)) continue;
            PhysicsBody o = statics[st];
            PhysPose pose = physPose(o);
            float3 local = pose.toBody(x);
            float depth = physDistance(shapes, o.info.x, local) - r;
            if (!(depth < 0.0f)) continue;
            float3 n = pose.direction(physGradient(shapes, o.info.x, local));
            float3 moved = x - prev;
            float overlap = min(-depth, max(-dot(moved, n), 0.0f) + PHYS_PUSH_SPEED * h);
            x += physParticlePush(n, overlap, moved, sqrt(p.velocity.w * o.velocity.w));
            slid += physCarSliding(moved, n, h);
        } else {
            PhysicsBody o = bodies[code];
            uint slot = k - firstBody;
            device atomic_int* mine = slot < PHYS_CAR_CARRIED ? carried + 6 * slot : nullptr;
            if (mine && done > 0 && o.position.w > 0.0f) {
                float3 push = float3(atomic_load_explicit(mine, memory_order_relaxed), atomic_load_explicit(mine + 1, memory_order_relaxed),
                                     atomic_load_explicit(mine + 2, memory_order_relaxed)) / PHYS_PUSH_FIXED;
                float3 twist = float3(atomic_load_explicit(mine + 3, memory_order_relaxed), atomic_load_explicit(mine + 4, memory_order_relaxed),
                                      atomic_load_explicit(mine + 5, memory_order_relaxed)) / PHYS_PUSH_FIXED;
                float3 dx = push * o.position.w, turn = physInvInertia(o.rotation, o.invInertia.xyz, twist);
                o.position.xyz += dx;
                o.rotation = physTurn(o.rotation, turn);
                o.velocity.xyz += dx / h;
                o.angular.xyz += turn / h;
            }
            float3 centre = o.position.xyz;
            float reach = r + o.invInertia.w;
            if (length_squared(x - centre) > reach * reach) continue;
            PhysPose pose = physPose(o);
            float3 local = pose.toBody(x);
            float depth = physDistance(shapes, o.info.x, local) - r;
            if (!(depth < 0.0f)) continue;
            float3 n = pose.direction(physGradient(shapes, o.info.x, local));
            float3 lever = x - centre;
            float3 surface = o.velocity.xyz + cross(o.angular.xyz, lever);
            float3 slide = (x - prev) - surface * h;
            float overlap = min(-depth, max(-dot(slide, n), 0.0f) + PHYS_PUSH_SPEED * h);
            float3 push = physParticlePush(n, overlap, slide, sqrt(p.velocity.w * o.velocity.w));
            slid += physCarSliding(slide, n, h);
            float l = length(push);
            if (!(l > 1e-9f)) continue;
            float wb = physWeight(o, lever, push / l) / max(shares[code], 1.0f);
            device atomic_int* a = acc + code * PHYS_BODY_WORDS;
            if ((o.info.y & PHYS_PIECE) != 0 && max(-dot(slide, n), 0.0f) > PHYS_IMPACT_SPEED * h) {
                float impulse = l / ((wn + wb) * h);
                atomic_fetch_add_explicit(a + PHYS_ACC_KNOCK, int(round(impulse * PHYS_KNOCK_FIXED)), memory_order_relaxed);
                physAddFixed(a + PHYS_ACC_KNOCK_POINT, x * impulse, PHYS_POINT_FIXED);
                physAddFixed(a + PHYS_ACC_KNOCK_PUSH, -n * impulse, PHYS_KNOCK_FIXED);
                atomic_fetch_or_explicit((device atomic_uint*)(a + PHYS_ACC_HITS), bit, memory_order_relaxed);
            }
            x += push * (wn / (wn + wb));
            if (wb > 0.0f) {
                float3 impulse = -push / (wn + wb);
                physAddFixed(a + PHYS_ACC_PUSH, impulse, PHYS_PUSH_FIXED);
                physAddFixed(a + PHYS_ACC_PUSH_TWIST, cross(lever, impulse), PHYS_PUSH_FIXED);
                atomic_fetch_add_explicit(a + PHYS_ACC_PUSHES, 1, memory_order_relaxed);
                if (mine) {
                    int3 f = int3(round(impulse * PHYS_PUSH_FIXED)), g = int3(round(cross(lever, impulse) * PHYS_PUSH_FIXED));
                    for (uint e = 0; e < 3; ++e) {
                        atomic_fetch_add_explicit(mine + e, f[e], memory_order_relaxed);
                        atomic_fetch_add_explicit(mine + 3 + e, g[e], memory_order_relaxed);
                    }
                }
            }
        }
    }
    q[i - base].position.xyz = x;
    if (any(slid != float2(0.0f))) wear[i] += slid;
}

// CarSolver.beamMiddle: a hull beam's middle against the statics; its push added (in fixed point) to both its nodes'.
inline void physCarMiddle(PhysicsCarBeam beam, threadgroup PhysCarNode* q, int base, threadgroup atomic_int* pushes, device const uint* candidates,
                          uint first, uint count, device const PhysicsBody* statics, device const float4* bounds, PhysicsShapes shapes,
                          float h) {
    int ia = int(beam.nodes.x) - base, ib = int(beam.nodes.y) - base;
    PhysCarNode qa = q[ia], qb = q[ib];
    if (!(qa.prevPosition.w > 0.0f) && !(qb.prevPosition.w > 0.0f)) return;
    float r = qa.position.w;
    float3 x = (qa.position.xyz + qb.position.xyz) * 0.5f, start = x;
    float3 moved = x - (qa.prevPosition.xyz + qb.prevPosition.xyz) * 0.5f;
    for (uint k = first; k < first + count; ++k) {
        uint code = candidates[k];
        if ((code & PHYS_STATIC) == 0) continue;
        uint st = code & ~PHYS_STATIC;
        if (!physNearStatic(bounds, st, x, r)) continue;
        PhysicsBody o = statics[st];
        PhysPose pose = physPose(o);
        float3 local = pose.toBody(x);
        float depth = physDistance(shapes, o.info.x, local) - r;
        if (!(depth < 0.0f)) continue;
        float3 n = pose.direction(physGradient(shapes, o.info.x, local));
        float overlap = min(-depth, max(-dot(moved, n), 0.0f) + PHYS_PUSH_SPEED * h);
        x += physParticlePush(n, overlap, moved, sqrt(qa.velocity.w * o.velocity.w));
    }
    float3 push = x - start;
    if (all(push == float3(0.0f))) return;
    int3 fixed = int3(round(push * PHYS_CAR_FIXED));
    for (uint e = 0; e < 2; ++e) {
        int i = e == 0 ? ia : ib;
        if (!(q[i].prevPosition.w > 0.0f)) continue;
        atomic_fetch_add_explicit(&pushes[4 * i], fixed.x, memory_order_relaxed);
        atomic_fetch_add_explicit(&pushes[4 * i + 1], fixed.y, memory_order_relaxed);
        atomic_fetch_add_explicit(&pushes[4 * i + 2], fixed.z, memory_order_relaxed);
        atomic_fetch_add_explicit(&pushes[4 * i + 3], 1, memory_order_relaxed);
    }
}

// A wheel's rim against the ground it stands on (the world's contact on the CPU: a rim touches only when its tyre
// bottoms out): its edge toward the nearest static, in its plane, pushed out (no friction: the tyre's).
inline void physCarRim(PhysicsCarWheel w, device PhysicsBody* bodies, device const uint* candidates, uint first, uint count,
                       device const PhysicsBody* statics, device const float4* bounds, PhysicsShapes shapes) {
    PhysicsBody o = physWheelBody(bodies, w);
    if (!physMoves(o)) return;
    float rim = w.radius - PHYS_TYRE_DEPTH;
    float3 a = quatRotate(o.rotation, w.axle);
    for (uint k = first; k < first + count; ++k) {
        uint code = candidates[k];
        if ((code & PHYS_STATIC) == 0) continue;
        uint st = code & ~PHYS_STATIC;
        float3 centre = o.position.xyz;
        if (!physNearStatic(bounds, st, centre, rim)) continue;
        PhysicsBody s = statics[st];
        PhysPose pose = physPose(s);
        float3 n = pose.direction(physGradient(shapes, s.info.x, pose.toBody(centre)));
        float3 down = -n + a * dot(n, a);
        float l = length(down);
        if (l <= 0.3f) continue;
        float3 edge = centre + down / l * rim;
        float depth = -physDistance(shapes, s.info.x, pose.toBody(edge));
        if (!(depth > 0.0f)) continue;
        o.position = float4(centre + n * depth, o.position.w);
    }
    physStoreWheel(bodies, w, o);
}

// Ordered appends across a threadgroup (the candidates, in the order the CPU finds them): each thread's `keep` given
// its place among this round's kept, the threads before it first; `total` the round's count.
inline uint physOrderedPlace(bool keep, uint t, uint lane, uint group, uint groups, threadgroup uint* sums, thread uint& total) {
    uint before = simd_prefix_exclusive_sum(uint(keep));
    uint mine = simd_sum(uint(keep));
    if (lane == 0) sums[group] = mine;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint earlier = 0;
    total = 0;
    for (uint g = 0; g < groups; ++g) {
        if (g < group) earlier += sums[g];
        total += sums[g];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    return earlier + before;
}

inline PhysicsBreakEvent physCarEvent(float4 position, float4 velocity) {
    PhysicsBreakEvent e;
    e.position = position;
    e.velocity = velocity;
    return e;
}

// MARK: - Kernels

// A step's start for each car (PhysicsWorld.beginCarStep, carBroadPhase): its commands, its box, what its nodes may
// meet (the statics near it, in their order), its wheels woken while it moves. A threadgroup a car.
kernel void physicsCarBeginKernel(constant PhysicsParams&        p          [[buffer(0)]],
                                  device PhysicsCar*             cars       [[buffer(1)]],
                                  device const PhysicsCarTune*   tunes      [[buffer(2)]],
                                  device PhysicsCarWheel*        wheels     [[buffer(3)]],
                                  device const PhysicsParticle*  q          [[buffer(4)]],
                                  device PhysicsBody*            bodies     [[buffer(5)]],
                                  device const PhysicsBody*      statics    [[buffer(6)]],
                                  device const float4*           bounds     [[buffer(7)]],
                                  device const PhysicsShape*     shapes     [[buffer(8)]],
                                  device uint*                   candidates [[buffer(9)]],
                                  device const uint4*            commands   [[buffer(10)]],   // count, then PhysicsFractureCommands
                                  device PhysicsCarClock&        clock      [[buffer(11)]],
                                  device PhysicsCarPart*         parts      [[buffer(22)]],
                                  device uint*                   partWake   [[buffer(23)]],   // per part: another car's node met it frozen
                                  constant uint4&                info       [[buffer(30)]],   // cars, fractured objects (1), bodies
                                  uint car   [[threadgroup_position_in_grid]],
                                  uint t     [[thread_index_in_threadgroup]],
                                  uint width [[threads_per_threadgroup]],
                                  uint lane  [[thread_index_in_simdgroup]],
                                  uint group [[simdgroup_index_in_threadgroup]],
                                  uint groups [[simdgroups_per_threadgroup]])
{
    threadgroup float3 los[32], his[32];
    threadgroup float fastests[32];
    threadgroup uint sums[32];
    threadgroup float3 momenta[32];
    threadgroup bool wakeAll, woken;
    PhysicsCar s = cars[car];
    // Its commands this step (PhysicsWorld.takeCarCommand), in the order they came.
    if (t == 0) {
        uint now = clock.counts.x, n = commands[0].x;
        device const PhysicsFractureCommand* list = (device const PhysicsFractureCommand*)(commands + 1);
        for (uint k = 0; k < n; ++k) {
            PhysicsFractureCommand c = list[k];
            if (c.info.y != PHYS_CAR_COMMAND || c.info.x != now || (c.info.z & 0xFFu) != car) continue;
            s.input = clamp(c.origin, float4(0, 0, -1, 0), float4(1, 1, 1, 1));
            s.lap = c.direction;
            s.flags = (s.flags & ~(PHYS_CAR_MANUAL | PHYS_CAR_AUTOPILOT)) | ((c.info.z & PHYS_CAR_CMD_MANUAL) != 0 ? PHYS_CAR_MANUAL : 0u)
                | ((c.info.z & PHYS_CAR_CMD_AUTOPILOT) != 0 ? PHYS_CAR_AUTOPILOT : 0u);
            int top = tunes[car].gearCount;
            if ((c.info.z & PHYS_CAR_SHIFT_UP) != 0 && s.gear < top) { s.gear += 1; s.shifting = 0.2f; }
            if ((c.info.z & PHYS_CAR_SHIFT_DOWN) != 0 && s.gear > -1) { s.gear -= 1; s.shifting = 0.2f; }
        }
        bool input = physHasInput(s);
        if ((s.flags & PHYS_CAR_ASLEEP) != 0 && input) {
            s.flags = (s.flags & ~PHYS_CAR_ASLEEP) | PHYS_CAR_AWAKE;
            s.still = 0.0f;
        }
        wakeAll = (s.flags & PHYS_CAR_AWAKE) != 0 || input;
        woken = false;
    }
    // Its box (the nodes', grown by how far they may go this step), and its fastest node.
    float3 lo = float3(INFINITY), hi = float3(-INFINITY);
    float fastest = 0.0f;
    for (int i = s.firstNode + int(t); i < s.firstNode + s.nodeCount; i += int(width)) {
        float3 x = q[i].position.xyz;
        lo = min(lo, x);
        hi = max(hi, x);
        fastest = max(fastest, length_squared(q[i].velocity.xyz));
    }
    lo = simd_min(lo);
    hi = simd_max(hi);
    fastest = simd_max(fastest);
    if (lane == 0) { los[group] = lo; his[group] = hi; fastests[group] = fastest; }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint g = 0; g < groups; ++g) { lo = min(lo, los[g]); hi = max(hi, his[g]); fastest = max(fastest, fastests[g]); }
    float reach = PHYS_CAR_NODE_RADIUS + sqrt(fastest) * PHYS_STEP + 0.15f;
    float3 centre = (lo + hi) * 0.5f;
    float radius = length(hi - lo) * 0.5f + reach;
    // The statics near it, in their order (PhysicsWorld.touchesStatic).
    uint found = 0, ns = p.counts.y, base = car * PHYS_CAR_CANDIDATES;
    for (uint first = 0; first < ns; first += width) {
        uint st = first + t;
        bool keep = false;
        if (st < ns) {
            PhysicsBody o = statics[st];
            if (shapes[o.info.x].info.x == PHYS_PLANE) {
                keep = dot(centre - o.position.xyz, quatRotate(o.rotation, float3(0, 1, 0))) < radius;
            } else {
                float3 nearest = clamp(centre, bounds[2 * st].xyz, bounds[2 * st + 1].xyz);
                keep = length_squared(centre - nearest) < radius * radius;
            }
        }
        uint total;
        uint at = found + physOrderedPlace(keep, t, lane, group, groups, sums, total);
        if (keep && at < PHYS_CAR_CANDIDATES) candidates[base + at] = st | PHYS_STATIC;
        found += total;
    }
    uint staticsFound = min(found, PHYS_CAR_CANDIDATES);
    // Then the bodies near it (its own wheels are kinematic to the world, of no mass, as the other cars' are: passed by,
    // as on the CPU its own are), and a fractured object's pieces held where they are; while it moves, those near it
    // woken; asleep, it wakes for one that moves near it.
    uint nb = info.z;
    bool active = wakeAll, asleep = (s.flags & PHYS_CAR_ASLEEP) != 0;
    for (uint first = 0; first < nb; first += width) {
        uint j = first + t;
        bool keep = false;
        if (j < nb) {
            PhysicsBody o = bodies[j];
            if ((o.info.y & PHYS_DISABLED) == 0 && (o.position.w > 0.0f || (o.info.y & PHYS_PIECE) != 0)) {
                float d = distance(o.position.xyz, centre), r = o.invInertia.w;
                keep = d < r + radius;
                if (keep && d < r + radius - 0.1f) {
                    if (asleep && physMoves(o)) woken = true;
                    if (active) {
                        // (A body's flags, info.y: its 30th word. Another car may wake it as well.)
                        atomic_fetch_and_explicit((device atomic_uint*)((device uint*)(bodies + j) + 29), ~PHYS_ASLEEP, memory_order_relaxed);
                        bodies[j].prevPosition.w = 0.0f;
                    }
                }
            }
        }
        uint total;
        uint at = found + physOrderedPlace(keep, t, lane, group, groups, sums, total);
        if (keep && at < PHYS_CAR_CANDIDATES) candidates[base + at] = j;
        found += total;
    }
    // Its momentum as the step begins (with fractured objects: what it gets back when they give way), summed in an
    // order that is always the same.
    float3 mine = float3(0.0f);
    if (info.y != 0) {
        for (int i = s.firstNode + int(t); i < s.firstNode + s.nodeCount; i += int(width)) {
            if (q[i].prevPosition.w > 0.0f) mine += q[i].velocity.xyz / q[i].prevPosition.w;
        }
        if (int(t) < s.wheelCount) {
            PhysicsCarWheel w = wheels[s.firstWheel + int(t)];
            float inverse = (w.flags & PHYS_WHEEL_OFF) != 0 ? bodies[w.body].position.w : w.inverseMass;
            if (inverse > 0.0f) mine += bodies[w.body].velocity.xyz / inverse;
        }
        mine = simd_sum(mine);
        if (lane == 0) momenta[group] = mine;
    }
    threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup);
    if (t == 0) {
        s.lo = float4(lo - reach, s.lo.w);
        s.hi = float4(hi + reach, 0.0f);
        s.candidateCount = int(min(found, PHYS_CAR_CANDIDATES));
        s.statics = staticsFound;
        if (info.y != 0) {
            float3 total = float3(0.0f);
            for (uint g = 0; g < groups; ++g) total += momenta[g];
            s.momentum = float4(total, 0.0f);
        }
        if (woken) {
            s.flags = (s.flags & ~PHYS_CAR_ASLEEP) | PHYS_CAR_AWAKE;
            s.still = 0.0f;
            wakeAll = true;
        }
        // Its parts that came off and froze, woken by a body near them (their nodes' mass back).
        for (int pi = 0; pi < s.partCount; ++pi) {
            PhysicsCarPart part = parts[s.firstPart + pi];
            if ((part.flags & PHYS_PART_FROZEN) == 0) continue;
            float3 x = q[part.firstNode].position.xyz;
            bool near = partWake[s.firstPart + pi] != 0;
            partWake[s.firstPart + pi] = 0;
            for (int k = 0; k < s.candidateCount && !near; ++k) {
                uint code = candidates[base + uint(k)];
                if ((code & PHYS_STATIC) != 0) continue;
                near = distance(bodies[code].position.xyz, x) < bodies[code].invInertia.w + 1.0f;
            }
            if (!near) continue;
            for (int i = part.firstNode; i < part.firstNode + part.nodeCount; ++i) {
                ((device PhysicsParticle*)q)[i].prevPosition.w = part.inverseMass;
            }
            part.flags &= ~PHYS_PART_FROZEN;
            part.still = 0.0f;
            parts[s.firstPart + pi] = part;
        }
        cars[car] = s;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    // Its wheels awake while it moves (the world's are another matter: they are kinematic to it).
    if (wakeAll && int(t) < s.wheelCount) {
        PhysicsCarWheel w = wheels[s.firstWheel + int(t)];
        if ((w.flags & PHYS_WHEEL_OFF) == 0) {
            bodies[w.body].info.y &= ~PHYS_ASLEEP;
            bodies[w.body].prevPosition.w = 0.0f;
        }
    }
}

// A group of a step's substeps for each car (PhysicsWorld.carForces, solveCars, the world's stages for its wheels): a
// threadgroup a car, its nodes in threadgroup memory for the group (each phase waits on them between its barriers).
// Each substep: the wheels read (a thread each), the drivetrain (one thread), the wheels' spins and the tyres (a thread
// each), the nodes and wheels moved; the axles; the beams a colour at a time; the corners again; the arms' loads; the
// nodes against the statics; the hull's middles; the velocities, and the wheels' rims against the ground.
kernel void physicsCarSubstepsKernel(constant PhysicsParams&        p            [[buffer(0)]],
                                     device PhysicsCar*             cars         [[buffer(1)]],
                                     device const PhysicsCarTune*   tunes        [[buffer(2)]],
                                     device PhysicsCarBeam*         beams        [[buffer(3)]],
                                     device PhysicsCarLimit*        limits       [[buffer(4)]],
                                     device float*                  loads        [[buffer(5)]],
                                     device float*                  lambdas      [[buffer(6)]],
                                     device PhysicsCarWheel*        wheels       [[buffer(7)]],
                                     device const uint*             reactions    [[buffer(8)]],
                                     device const uint*             colours      [[buffer(9)]],    // the beams in their colours
                                     device const uint*             colourStarts [[buffer(10)]],
                                     device const uint*             candidates   [[buffer(11)]],
                                     device PhysicsParticle*        particles    [[buffer(12)]],
                                     device PhysicsBody*            bodies       [[buffer(13)]],
                                     device const PhysicsBody*      statics      [[buffer(14)]],
                                     device const float4*           bounds       [[buffer(15)]],
                                     device const PhysicsShape*     shapes       [[buffer(16)]],
                                     device const float4*           samples      [[buffer(17)]],
                                     device const SDFScene&         sdf          [[buffer(18)]],
                                     device float2*                 wear         [[buffer(19)]],
                                     constant PhysicsGroup&         run          [[buffer(21)]],
                                     device atomic_int*             acc          [[buffer(22)]],   // per body (PHYS_BODY_WORDS)
                                     device const float*            shares       [[buffer(23)]],   // per body
                                     device atomic_int*             carriedAll   [[buffer(24)]],   // per car, 6 x PHYS_CAR_CARRIED
                                     uint car   [[threadgroup_position_in_grid]],
                                     uint t     [[thread_index_in_threadgroup]],
                                     uint width [[threads_per_threadgroup]])
{
    threadgroup PhysCarNode q[PHYS_CAR_NODES];
    threadgroup uint4 scratch[PHYS_CAR_SCRATCH / 16];
    threadgroup atomic_int* middles = (threadgroup atomic_int*)scratch;
    threadgroup PhysicsCarBeam* cornerBeams = (threadgroup PhysicsCarBeam*)scratch;
    threadgroup float* cornerLambdas = (threadgroup float*)(cornerBeams + PHYS_CAR_CORNERS);
    threadgroup PhysWheelNow wn[8];
    threadgroup float3 drag;
    threadgroup float turn;
    PhysicsCar s = cars[car];
    if ((s.flags & PHYS_CAR_ASLEEP) != 0) return;
    // (`run` is one substep of a world group: `wide` its place in it, `last` the group's substeps. A car in a pair takes
    // that one substep, the others meeting it after (physicsCarMeetKernel); one alone takes the whole group at its first.)
    bool paired = (s.flags & PHYS_CAR_PAIRED) != 0;
    if (!paired && run.wide != 0) return;
    uint substeps = paired ? 1u : run.last;
    PhysicsShapes w = {shapes, samples, sdf};
    PhysicsCarTune tune = tunes[car];
    float h = p.gravity.w;
    uint firstCandidate = car * PHYS_CAR_CANDIDATES, candidateCount = uint(s.candidateCount);
    int base = s.firstNode, nodes = min(s.nodeCount, PHYS_CAR_NODES), endNode = base + nodes;
    int firstBeam = s.firstBeam, endBeam = s.firstBeam + s.beamCount;
    int fw = s.firstWheel, wheelCount = min(s.wheelCount, 8);
    int i0 = int(t), stride = int(width);
    for (int i = i0; i < nodes; i += stride) {
        PhysicsParticle n = particles[base + i];
        q[i].position = n.position;
        q[i].velocity = n.velocity;
        q[i].prevPosition = n.prevPosition;
    }
    // (Its pushes carried through the group: in device memory, a paired car's group being a dispatch a substep.)
    device atomic_int* carried = carriedAll + car * 6 * PHYS_CAR_CARRIED;
    if (run.wide == 0) {
        for (uint k = t; k < 6 * PHYS_CAR_CARRIED; k += width) atomic_store_explicit(&carried[k], 0, memory_order_relaxed);
        threadgroup_barrier(mem_flags::mem_device);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint sub = 0; sub < substeps; ++sub) {
        // Each wheel as it is (its spin and inverse inertia about its axle, what its tyre found the substep before).
        if (i0 < wheelCount) {
            PhysicsCarWheel wh = wheels[fw + i0];
            PhysicsBody o = physWheelBody(bodies, wh);
            float3 a = quatRotate(o.rotation, wh.axle);
            PhysWheelNow now;
            now.axis = a;
            now.spin = dot(o.angular.xyz, a);
            now.inverse = physTurnWeight(o, a);
            now.load = wh.load;
            now.over = wh.over;
            now.radius = wh.radius;
            now.brake = wh.brake;
            now.flags = wh.flags;
            now.dw = 0.0f;
            now.brakeDw = 0.0f;
            wn[i0] = now;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        // The drivetrain.
        if (t == 0) {
            float3 d;
            float tr;
            physCarDrive(s, tune, wn, wheelCount, q, base, reactions, h, run.first + sub, d, tr);
            drag = d;
            turn = tr;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        // Each wheel's spin changed (the drive's, the differential's, the brake's), its knuckle turned by its brake,
        // its tie rod's length the steering's; then its tyre (of the wheels still on).
        if (i0 < wheelCount) {
            int wk = fw + i0;
            PhysicsCarWheel wh = wheels[wk];
            PhysWheelNow now = wn[i0];
            if (wh.tie >= 0) {
                PhysicsCarLimit limit = limits[wh.tie];
                beams[wh.tie].rest = limit.rest0 + limit.bend + limit.steer * turn;
            }
            if (now.dw != 0.0f) {
                PhysicsBody o = physWheelBody(bodies, wh);
                if (physMoves(o)) {
                    o.angular.xyz += now.axis * now.dw;
                    physStoreWheel(bodies, wh, o);
                }
            }
            if (now.brakeDw != 0.0f && now.inverse > 0.0f) physKnuckleCouple(-now.axis * (now.brakeDw / now.inverse), wh, q, base);
            if ((wh.flags & PHYS_WHEEL_OFF) == 0) {
                physCarTyre(wheels, wk, tune, candidates, firstCandidate, candidateCount, q, base, bodies, acc, statics, bounds, w, h);
            }
        }
        threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup);
        // The nodes moved (their velocities, gravity, the air), and the wheels (as the world moves a body, uncapped).
        float3 gravity = p.gravity.xyz * h, air = drag;
        for (int i = i0; i < nodes; i += stride) {
            PhysCarNode n = q[i];
            if (!(n.prevPosition.w > 0.0f)) continue;
            float3 x = n.position.xyz, u = n.velocity.xyz + gravity + air;
            q[i].prevPosition.xyz = x;
            q[i].velocity.xyz = u;
            q[i].position.xyz = x + u * h;
        }
        if (i0 < wheelCount && (wheels[fw + i0].flags & PHYS_WHEEL_OFF) == 0) {
            PhysicsCarWheel wh = wheels[fw + i0];
            PhysicsBody o = physWheelBody(bodies, wh);
            if (physMoves(o)) {
                o.prevPosition = float4(o.position.xyz, o.prevPosition.w);
                o.prevRotation = o.rotation;
                float3 v = o.velocity.xyz + gravity;
                o.velocity = float4(v, o.velocity.w);
                o.position = float4(o.position.xyz + v * h, o.position.w);
                o.rotation = physTurn(o.rotation, o.angular.xyz * h);
                physStoreWheel(bodies, wh, o);
            }
        }
        for (int k = firstBeam + i0; k < endBeam; k += stride) lambdas[k] = 0.0f;
        threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup);
        // The axles (each wheel its own hubs and body: its two passes on its own thread).
        if (i0 < wheelCount && (wheels[fw + i0].flags & PHYS_WHEEL_OFF) == 0) {
            for (uint pass = 0; pass < PHYS_AXLE_PASSES; ++pass) physCarAxle(wheels, fw + i0, q, base, bodies, h);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        // The beams, a colour at a time (no two of a colour share a node). On the GPU a car's beams are in their colours'
        // order (CarsGPU), a colour's one run: each thread reads its beam of the next colour before the barrier, so the
        // read overlaps the colour before. (Its lambda is 0 on this pass: zeroed above.)
        int lastColour = s.firstColour + s.colourCount;
        uint end = colourStarts[s.firstColour];
        PhysicsCarBeam next = end + t < colourStarts[s.firstColour + 1] ? beams[end + t] : PhysicsCarBeam();
        for (int c = s.firstColour; c < lastColour; ++c) {
            uint k = end + t;
            end = colourStarts[c + 1];
            PhysicsCarBeam beam = next;
            if (c + 1 < lastColour && end + t < colourStarts[c + 2]) next = beams[end + t];
            if (k < end) physCarBeam(k, beam, 0.0f, beams, lambdas, loads, limits, q, base, h, true);
            for (uint more = k + width; more < end; more += width) physCarBeam(more, beams[more], 0.0f, beams, lambdas, loads, limits, q, base, h, true);
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        // The corners again, while each is well short of its yield: their beams (and lambdas, as the pass above left
        // them) into threadgroup memory, their passes there, a colour at a time (their list in its own colours); then
        // the arms' loads.
        threadgroup_barrier(mem_flags::mem_device);
        uint cornerFirst = colourStarts[s.cornerColour], cornerEnd = colourStarts[s.cornerColour + s.cornerColours];
        for (uint at = cornerFirst + t; at < cornerEnd; at += width) {
            uint k = colours[at];
            cornerBeams[at - cornerFirst] = beams[k];
            cornerLambdas[at - cornerFirst] = lambdas[k];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint pass = 0; pass < PHYS_CORNER_PASSES; ++pass) {
            for (int c = s.cornerColour; c < s.cornerColour + s.cornerColours; ++c) {
                for (uint at = colourStarts[c] + t; at < colourStarts[c + 1]; at += width) {
                    uint j = at - cornerFirst;
                    PhysicsCarBeam beam = cornerBeams[j];
                    if (abs(beam.load) < 0.5f * beam.yield) physCarCorner(beam, cornerLambdas[j], q, base, h);
                }
                threadgroup_barrier(mem_flags::mem_threadgroup);
            }
        }
        for (uint at = cornerFirst + t; at < cornerEnd; at += width) {
            uint k = colours[at], j = at - cornerFirst;
            PhysicsCarBeam beam = cornerBeams[j];
            if (physBeamZone(beam.info) != PHYS_ZONE_ARM || (beam.info & PHYS_BEAM_BROKEN) != 0) continue;
            physCarFlow(k, beam, -cornerLambdas[j] / (h * h), loads, limits);
            beams[k] = beam;
        }
        // The nodes against the statics.
        for (int i = base + i0; i < endNode; i += stride) {
            physCarNode(i, q, base, wear, candidates, firstCandidate, candidateCount, statics, bounds, bodies, acc, shares, 1u << car, carried,
                        firstCandidate + s.statics, run.wide + sub, w, h);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        // The hull's middles against the statics: each pushes its two nodes, each node by the mean of its pushes (summed
        // in the scratch, the corners done with it).
        for (int i = i0; i < 4 * nodes; i += stride) atomic_store_explicit(&middles[i], 0, memory_order_relaxed);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (int k = firstBeam + i0; k < endBeam; k += stride) {
            PhysicsCarBeam beam = beams[k];
            if ((beam.info & (PHYS_BEAM_HULL | PHYS_BEAM_BROKEN)) != PHYS_BEAM_HULL) continue;
            physCarMiddle(beam, q, base, middles, candidates, firstCandidate, candidateCount, statics, bounds, w, h);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (int i = i0; i < nodes; i += stride) {
            int n = atomic_load_explicit(&middles[4 * i + 3], memory_order_relaxed);
            if (n == 0) continue;
            int3 sum = int3(atomic_load_explicit(&middles[4 * i], memory_order_relaxed), atomic_load_explicit(&middles[4 * i + 1], memory_order_relaxed),
                            atomic_load_explicit(&middles[4 * i + 2], memory_order_relaxed));
            q[i].position.xyz += float3(sum) / (PHYS_CAR_FIXED * float(n));
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        // The velocities: the nodes' from how far they went (capped), the wheels' after their rims met the ground.
        for (int i = i0; i < nodes; i += stride) {
            PhysCarNode n = q[i];
            float3 v = (n.position.xyz - n.prevPosition.xyz) / h;
            float speed = length(v);
            if (speed > PHYS_CAR_TOP_SPEED) v *= PHYS_CAR_TOP_SPEED / speed;
            q[i].velocity.xyz = v;
        }
        if (i0 < wheelCount && (wheels[fw + i0].flags & PHYS_WHEEL_OFF) == 0) {
            PhysicsCarWheel wh = wheels[fw + i0];
            physCarRim(wh, bodies, candidates, firstCandidate, candidateCount, statics, bounds, w);
            PhysicsBody o = physWheelBody(bodies, wh);
            if (physMoves(o)) physStoreWheel(bodies, wh, physTaken(o, h));
        }
        threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup);
    }
    for (int i = i0; i < nodes; i += stride) {
        particles[base + i].position = q[i].position;
        particles[base + i].velocity = q[i].velocity;
        particles[base + i].prevPosition = q[i].prevPosition;
    }
    if (t == 0) {
        // (Only the drivetrain's fields are this kernel's: the rest are the step's.)
        cars[car].controls = s.controls;
        cars[car].input = s.input;
        cars[car].gear = s.gear;
        cars[car].engine = s.engine;
        cars[car].shifting = s.shifting;
        cars[car].clutch = s.clutch;
        cars[car].sinceShift = s.sinceShift;
    }
}

// A step's end for each car (PhysicsWorld.endCarStep: CarSolver.breakBeams, damage; the telemetry, the sleep): a
// threadgroup a car.
kernel void physicsCarEndKernel(constant PhysicsParams&        p          [[buffer(0)]],
                                device PhysicsCar*             cars       [[buffer(1)]],
                                device PhysicsCarBeam*         beams      [[buffer(3)]],
                                device const PhysicsCarLimit*  limits     [[buffer(4)]],
                                device float*                  loads      [[buffer(5)]],
                                device PhysicsCarWheel*        wheels     [[buffer(7)]],
                                device const uint*             reactions  [[buffer(8)]],
                                device PhysicsParticle*        q          [[buffer(12)]],
                                device PhysicsBody*            bodies     [[buffer(13)]],
                                device float2*                 wear       [[buffer(19)]],
                                device atomic_uint*            crush      [[buffer(20)]],   // per particle (the middles' pushes' first word)
                                device PhysicsCarPart*         parts      [[buffer(22)]],
                                device PhysicsCarPane*         panes      [[buffer(23)]],
                                device const uint*             paneFrames [[buffer(24)]],
                                device const uint*             radiator   [[buffer(25)]],
                                device const float*            reachOf    [[buffer(26)]],
                                device PhysicsBreakEvent*      events     [[buffer(27)]],   // PHYS_CAR_EVENTS a car
                                device PhysicsCarTelemetry*    telemetry  [[buffer(28)]],
                                uint car   [[threadgroup_position_in_grid]],
                                uint t     [[thread_index_in_threadgroup]],
                                uint width [[threads_per_threadgroup]])
{
    PhysicsCar s = cars[car];
    if ((s.flags & PHYS_CAR_ASLEEP) != 0) return;
    threadgroup atomic_int counts[2];        // bent, broken
    threadgroup atomic_int holding[16];      // each part's attachments left
    threadgroup uint tearing, lettingGo;     // the parts whose attachments tear, whose supports let go (bits)
    threadgroup bool sleeping;
    float substeps = p.softDamping.z, step = PHYS_STEP;
    int firstBeam = s.firstBeam, endBeam = s.firstBeam + s.beamCount;
    int firstNode = s.firstNode, endNode = s.firstNode + s.nodeCount;
    if (t < 2) atomic_store_explicit(&counts[t], 0, memory_order_relaxed);
    if (t < 16) atomic_store_explicit(&holding[t], 0, memory_order_relaxed);
    if (t == 0) { tearing = 0; lettingGo = 0; sleeping = false; }
    for (int i = firstNode + int(t); i < endNode; i += int(width)) atomic_store_explicit(&crush[4 * i], 0u, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup);
    // Its beams' loads over the step: what broke; how many are bent and broken (CarSolver.breakBeams). Its nodes'
    // crush from the plastic beams on them.
    for (int k = firstBeam + int(t); k < endBeam; k += int(width)) {
        float load = loads[k] / substeps;
        loads[k] = 0.0f;
        PhysicsCarBeam beam = beams[k];
        uint kind = physBeamKind(beam.info);
        bool steer = kind == PHYS_BEAM_STEER;
        if (kind != PHYS_BEAM_PLASTIC && !steer) continue;
        PhysicsCarLimit limit = limits[k];
        float flow = steer ? limit.bend : beam.rest - limit.rest0;
        if ((beam.info & PHYS_BEAM_BROKEN) == 0 && (abs(load) > limit.strength || abs(flow) > limit.strainLimit * limit.rest0)) {
            beam.info |= PHYS_BEAM_BROKEN;
            beams[k] = beam;
        }
        bool broken = (beam.info & PHYS_BEAM_BROKEN) != 0;
        if (broken) atomic_fetch_add_explicit(&counts[1], 1, memory_order_relaxed);
        else if (abs(flow) > 0.01f * limit.rest0) atomic_fetch_add_explicit(&counts[0], 1, memory_order_relaxed);
        if (kind != PHYS_BEAM_PLASTIC || (beam.info & PHYS_BEAM_ATTACH) != 0) continue;
        float strain = broken ? PHYS_CRUSH_STRAIN : abs(beam.rest - limit.rest0) / limit.rest0;
        if (!(strain > 0.004f)) continue;
        uint c = uint(min(strain / PHYS_CRUSH_STRAIN, 1.0f) * 255.0f);
        atomic_fetch_max_explicit(&crush[4 * beam.nodes.x], c, memory_order_relaxed);
        atomic_fetch_max_explicit(&crush[4 * beam.nodes.y], c, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_device);
    // The nodes' crush, scrapes and dirt (CarSolver.crushNode, wearNodes).
    float2 per = float2(255.0f / PHYS_SCRAPE_LENGTH, 255.0f / PHYS_DIRT_LENGTH);
    for (int i = firstNode + int(t); i < endNode; i += int(width)) {
        uint z = q[i].info.z, c = atomic_load_explicit(&crush[4 * i], memory_order_relaxed);
        if (c > (z & 0xFFu)) z = (z & ~0xFFu) | c;
        float2 wr = wear[i];
        if (wr.x * per.x >= 1.0f || wr.y * per.y >= 1.0f) {
            float2 bytes = floor(wr * per);
            wear[i] = wr - bytes / per;
            uint scrape = min(((z >> 8) & 0xFFu) + uint(bytes.x), 255u), dirt = min(((z >> 16) & 0xFFu) + uint(bytes.y), 255u);
            z = (z & 0xFF0000FFu) | scrape << 8 | dirt << 16;
        }
        q[i].info.z = z;
        atomic_store_explicit(&crush[4 * i], 0u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_device);
    // What holds each part on: an attachment whose body node is crushed breaks.
    for (int k = firstBeam + int(t); k < endBeam; k += int(width)) {
        PhysicsCarBeam beam = beams[k];
        if ((beam.info & (PHYS_BEAM_ATTACH | PHYS_BEAM_BROKEN)) != PHYS_BEAM_ATTACH) continue;
        int part = physBeamPart(beam.info);
        if ((q[beam.nodes.y].info.z & 0xFFu) >= PHYS_MOUNT_CRUSH) {
            beams[k].info = beam.info | PHYS_BEAM_BROKEN;
        } else if (part > 0 && part <= 16) {
            atomic_fetch_add_explicit(&holding[part - 1], 1, memory_order_relaxed);
        }
    }
    threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup);
    // Its parts: off when nothing holds them (torn off with less than half left), frozen once still for a second.
    int fired = 0;
    if (t == 0) {
        for (int pi = 0; pi < s.partCount; ++pi) {
            PhysicsCarPart part = parts[s.firstPart + pi];
            if ((part.flags & PHYS_PART_OFF) == 0) {
                part.holding = pi < 16 ? atomic_load_explicit(&holding[pi], memory_order_relaxed) : 1;
                if (part.holding > 0 && part.holding * PHYS_TORN_BELOW < part.attachments) {
                    tearing |= 1u << uint(pi);
                    part.holding = 0;
                }
                if (part.holding == 0) {
                    part.flags |= PHYS_PART_OFF;
                    s.partsOff += 1;
                    lettingGo |= 1u << uint(pi);
                    float3 middle = float3(0.0f);
                    for (int i = part.firstNode; i < part.firstNode + part.nodeCount; ++i) middle += q[i].position.xyz;
                    middle /= float(max(part.nodeCount, 1));
                    if (fired < int(PHYS_CAR_EVENTS)) {
                        events[car * PHYS_CAR_EVENTS + uint(fired++)] = physCarEvent(float4(middle, 0.4f), float4(q[part.firstNode].velocity.xyz, float(PHYS_EVENT_DEBRIS)));
                    }
                }
            } else if ((part.flags & PHYS_PART_FROZEN) == 0) {
                float fastest = 0.0f;
                for (int i = part.firstNode; i < part.firstNode + part.nodeCount; ++i) fastest = max(fastest, length_squared(q[i].velocity.xyz));
                part.still = fastest < PHYS_STILL_SPEED * PHYS_STILL_SPEED ? part.still + step : 0.0f;
                if (part.still > PHYS_FREEZE_AFTER) {
                    part.flags |= PHYS_PART_FROZEN;
                    for (int i = part.firstNode; i < part.firstNode + part.nodeCount; ++i) {
                        q[i].prevPosition = float4(q[i].position.xyz, 0.0f);
                        q[i].velocity = float4(0.0f, 0.0f, 0.0f, q[i].velocity.w);
                    }
                }
            }
            parts[s.firstPart + pi] = part;
        }
    }
    threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup);
    // The torn parts' attachments, the parts that came off their supports (CarSolver.tear, letGo).
    if (tearing != 0 || lettingGo != 0) {
        for (int k = firstBeam + int(t); k < endBeam; k += int(width)) {
            uint info = beams[k].info;
            int part = physBeamPart(info);
            if (part < 1 || part > 32) continue;
            uint bit = 1u << uint(part - 1);
            bool tear = (tearing & bit) != 0 && (info & PHYS_BEAM_ATTACH) != 0;
            bool let = (lettingGo & bit) != 0 && physBeamKind(info) == PHYS_BEAM_SUPPORT;
            if (tear || let) beams[k].info = info | PHYS_BEAM_BROKEN;
        }
        threadgroup_barrier(mem_flags::mem_device);
    }
    if (t == 0) {
        PhysCarFrame frame = physCarFrame(s, q, 0);
        // Its wheels: off its axle past its knock, or with its knuckle's links broken.
        for (int k = s.firstWheel; k < s.firstWheel + s.wheelCount; ++k) {
            PhysicsCarWheel w = wheels[k];
            float knock = w.axleKnock;
            w.knockPeak = max(w.knockPeak, knock);
            w.axleKnock = 0.0f;
            int lost = 0;
            for (int j = 0; j < 8; ++j) if (w.links[j] >= 0 && (beams[w.links[j]].info & PHYS_BEAM_BROKEN) != 0) lost += 1;
            if ((w.flags & PHYS_WHEEL_OFF) == 0 && (knock > PHYS_AXLE_STRENGTH || lost >= PHYS_LINKS_LOST)) {
                w.flags = PHYS_WHEEL_OFF | (w.flags & PHYS_WHEEL_FRONT);
                w.brake = 0.0f;
                w.tie = -1;
                s.wheelsOff += 1;
                // A body of the world's again: its mass, friction and bounce back.
                PhysicsBody o = bodies[w.body];
                o.position.w = w.inverseMass;
                o.velocity.w = 0.8f;
                o.angular.w = 0.2f;
                o.info.y &= ~(PHYS_WHEEL | PHYS_KINEMATIC | PHYS_ASLEEP);
                o.prevPosition.w = 0.0f;
                bodies[w.body] = o;
            }
            wheels[k] = w;
        }
        // Its panes and lamps.
        for (int j = 0; j < s.paneCount; ++j) {
            PhysicsCarPane pane = panes[s.firstPane + j];
            if (pane.broken != 0) continue;
            float strain = 0.0f;
            for (int f = pane.firstFrame; f < pane.firstFrame + pane.frameCount; ++f) {
                uint k = paneFrames[f];
                PhysicsCarBeam beam = beams[k];
                PhysicsCarLimit limit = limits[k];
                float stretch = (beam.info & PHYS_BEAM_BROKEN) != 0 ? limit.rest0
                    : abs(beam.rest - limit.rest0) + (pane.lamp != 0 ? 0.0f : abs(beam.load) * beam.compliance);
                strain = max(strain, stretch / limit.rest0);
            }
            bool off = pane.part > 0 && (parts[s.firstPart + pane.part - 1].flags & PHYS_PART_OFF) != 0;
            if (!off && !(strain > (pane.lamp != 0 ? PHYS_LAMP_STRAIN : PHYS_GLASS_STRAIN))) continue;
            pane.broken = 1;
            panes[s.firstPane + j] = pane;
            s.panesBroken += 1;
            q[firstNode + j / 8].info.z |= 1u << uint(24 + j % 8);
            for (int corner = 0; corner < (pane.lamp != 0 ? 1 : 4); ++corner) {
                uint i = pane.corners[corner];
                if (fired < int(PHYS_CAR_EVENTS)) {
                    events[car * PHYS_CAR_EVENTS + uint(fired++)] = physCarEvent(float4(q[i].position.xyz, pane.lamp != 0 ? 0.1f : 0.25f),
                                                                      float4(q[i].velocity.xyz, float(PHYS_EVENT_GLASS)));
                }
            }
        }
        // Its engine: the front pushed back toward it (the mean of the four furthest back).
        float3 engine = float3(0.0f);
        for (int k = s.firstReaction; k < s.firstReaction + s.reactionCount; ++k) engine += q[reactions[k]].position.xyz;
        engine /= float(max(s.reactionCount, 1));
        float4 worst = float4(0.0f);
        for (int k = s.firstRadiator; k < s.firstRadiator + s.radiatorCount; ++k) {
            float back = reachOf[k] - dot(q[radiator[k]].position.xyz - engine, frame.forward);
            if (back > worst[0]) {
                worst[0] = back;
                for (int j = 1; j < 4; ++j) if (worst[j - 1] > worst[j]) { float x = worst[j - 1]; worst[j - 1] = worst[j]; worst[j] = x; }
            }
        }
        s.frontCrush = max((worst[0] + worst[1] + worst[2] + worst[3]) / 4.0f, 0.0f);
        float leak = clamp((s.frontCrush - PHYS_RADIATOR_CRUSH) / PHYS_RADIATOR_SPAN, 0.0f, 1.0f);
        s.coolant = max(s.coolant - leak * PHYS_COOLANT_LOSS * step, 0.0f);
        s.engineDamage = max(s.engineDamage, clamp((s.frontCrush - PHYS_BLOCK_CRUSH) / PHYS_BLOCK_SPAN, 0.0f, 1.0f));
        bool running = (s.flags & PHYS_CAR_RUNNING) != 0;
        float cooled = min(s.coolant / 0.3f, 1.0f), work = running ? 0.3f + 0.7f * s.controls.x : 0.0f;
        s.heat = clamp(s.heat + (work * (1.0f - cooled) * PHYS_HEATING - cooled * PHYS_COOLING) * step, 0.0f, 1.0f);
        if (s.heat >= 1.0f) s.engineDamage = 1.0f;
        if (s.engineDamage >= 1.0f) s.flags &= ~PHYS_CAR_RUNNING;
        s.sinceSmoke += 1;
        if (s.sinceSmoke >= PHYS_SMOKE_EVERY && ((leak > 0.0f && s.coolant > 0.0f) || s.heat > 0.6f || s.engineDamage > 0.5f)) {
            s.sinceSmoke = 0;
            bool smoke = s.heat > 0.6f || s.engineDamage > 0.5f;
            if (fired < int(PHYS_CAR_EVENTS)) {
                events[car * PHYS_CAR_EVENTS + uint(fired++)] = physCarEvent(float4(engine + frame.up * 0.35f + frame.forward * 0.3f, 0.25f),
                                                                  float4(frame.velocity + frame.up * 1.2f, float(smoke ? PHYS_EVENT_SMOKE : PHYS_EVENT_STEAM)));
            }
        }
        s.eventCount = fired;
        s.bent = atomic_load_explicit(&counts[0], memory_order_relaxed);
        s.broken = atomic_load_explicit(&counts[1], memory_order_relaxed);
        // What a frame shows of it (PhysicsWorld.carTelemetry), and whether it sleeps.
        float3 centre = float3(0.0f);
        for (int i = firstNode; i < firstNode + s.ringNodes; ++i) centre += q[i].position.xyz;
        centre /= float(max(s.ringNodes, 1));
        float speed = dot(frame.velocity, frame.forward);
        PhysicsCarTelemetry tm;
        tm.position = float4(frame.centre, speed);
        tm.centre = float4(centre, s.engine * 30.0f / M_PI_F);
        tm.forward = float4(frame.forward, s.controls.x);
        tm.up = float4(frame.up, s.controls.y);
        tm.steer = s.controls.w;
        tm.gear = s.gear;
        tm.bent = s.bent;
        tm.broken = s.broken;
        tm.frontCrush = s.frontCrush;
        tm.coolant = s.coolant;
        tm.heat = s.heat;
        tm.engineDamage = s.engineDamage;
        tm.partsOff = s.partsOff;
        tm.wheelsOff = s.wheelsOff;
        tm.panesBroken = s.panesBroken;
        bool awake = abs(speed) > 0.05f || physHasInput(s) || s.controls.x > 0.0f || s.controls.w != 0.0f;
        s.flags = awake ? s.flags | PHYS_CAR_AWAKE : s.flags & ~PHYS_CAR_AWAKE;
        s.still = awake ? 0.0f : s.still + step;
        // Still long enough, its wheels still too: it sleeps, its nodes at rest, its wheels asleep.
        bool wheelsStill = true;
        for (int k = s.firstWheel; k < s.firstWheel + s.wheelCount; ++k) {
            PhysicsCarWheel wk = wheels[k];
            if ((wk.flags & PHYS_WHEEL_OFF) != 0) continue;
            PhysicsBody o = bodies[wk.body];
            if (length(o.velocity.xyz) > p.sleep.x || length(o.angular.xyz) * wk.radius > p.sleep.y) wheelsStill = false;
        }
        if (s.still > PHYS_CAR_SLEEP_AFTER && wheelsStill) {
            s.flags |= PHYS_CAR_ASLEEP;
            sleeping = true;
            for (int k = s.firstWheel; k < s.firstWheel + s.wheelCount; ++k) {
                PhysicsCarWheel wk = wheels[k];
                if ((wk.flags & PHYS_WHEEL_OFF) != 0) continue;
                bodies[wk.body].velocity.xyz = float3(0.0f);
                bodies[wk.body].angular.xyz = float3(0.0f);
                bodies[wk.body].info.y |= PHYS_ASLEEP;
            }
        }
        tm.flags = (s.flags & PHYS_CAR_RUNNING) | ((s.flags & PHYS_CAR_ASLEEP) != 0 ? PHYS_CAR_ASLEEP : 0u);
        telemetry[car] = tm;
        // (The drivetrain's fields are the substeps' kernel's: as they left them.)
        cars[car].still = s.still;
        cars[car].flags = s.flags;
        cars[car].frontCrush = s.frontCrush;
        cars[car].coolant = s.coolant;
        cars[car].heat = s.heat;
        cars[car].engineDamage = s.engineDamage;
        cars[car].bent = s.bent;
        cars[car].broken = s.broken;
        cars[car].partsOff = s.partsOff;
        cars[car].wheelsOff = s.wheelsOff;
        cars[car].panesBroken = s.panesBroken;
        cars[car].sinceSmoke = s.sinceSmoke;
        cars[car].eventCount = s.eventCount;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (sleeping) {
        for (int i = firstNode + int(t); i < endNode; i += int(width)) q[i].velocity.xyz = float3(0.0f);
    }
}

// The step's cars' events into the ring of breaks (after the fractured objects', in the cars' order), and the clock
// moved on: one thread.
kernel void physicsCarEventsKernel(device PhysicsCar*              cars   [[buffer(1)]],
                                   device const PhysicsBreakEvent* events [[buffer(27)]],
                                   device PhysicsCarClock&         clock  [[buffer(11)]],
                                   device uint4*                   ring   [[buffer(29)]],
                                   constant uint&                  count  [[buffer(30)]],   // cars
                                   uint t [[thread_position_in_grid]])
{
    if (t != 0) return;
    uint step = clock.counts.x, slot = step % PHYS_RING_SLOTS;
    uint4 header = ring[slot];
    uint at = header.x == step + 1 ? header.y : 0u;   // (after the fractured objects' breaks of this step, if any)
    device PhysicsBreakEvent* out = (device PhysicsBreakEvent*)(ring + PHYS_RING_SLOTS) + slot * PHYS_RING_EVENTS;
    for (uint c = 0; c < count; ++c) {
        int n = cars[c].eventCount;
        for (int k = 0; k < n && at < PHYS_RING_EVENTS; ++k) out[at++] = events[c * PHYS_CAR_EVENTS + uint(k)];
        cars[c].eventCount = 0;
    }
    ring[slot] = uint4(step + 1, at, 0, 0);
    clock.counts.x = step + 1;
}

// The cars' telemetry for a frame slot (the CPU reads it once the slot's frame is done): the step, then each car's.
kernel void physicsCarTelemetryKernel(device const PhysicsCarTelemetry* telemetry [[buffer(28)]],
                                      device const PhysicsCarClock&     clock     [[buffer(11)]],
                                      device uint4*                     out       [[buffer(29)]],
                                      constant uint&                    count     [[buffer(30)]],
                                      uint t [[thread_position_in_grid]])
{
    if (t == 0) out[0] = uint4(clock.counts.x, count, 0, 0);
    if (t < count) ((device PhysicsCarTelemetry*)(out + 1))[t] = telemetry[t];
}

// MARK: - Cars against cars (CarContacts.swift)

// A pair of cars that may meet this step (PhysicsWorld.pairCars; a car with itself while one of its parts is off): its
// cars and colour. An island: the pairs whose cars meet (firstPair, pairCount, its cars' place in `islandCars`, count).
struct PhysicsCarPair { uint a, b, colour, pad; };

// The step's pairs (one thread, after the cars' starts): each car with itself while one of its parts is off, each two
// whose boxes meet; coloured as the CPU colours them (a pair the first colour neither car has yet), in the cars' order;
// a car asleep that an awake one comes up to woken (with its wheels); the pairs in islands (cars joined by pairs), each
// island's in colour order; the paired cars marked (a substep a dispatch); the meet's dispatch (an island a threadgroup).
kernel void physicsCarPairsKernel(device PhysicsCar*             cars       [[buffer(1)]],
                                  device const PhysicsCarWheel*  wheels     [[buffer(7)]],
                                  device PhysicsBody*            bodies     [[buffer(13)]],
                                  device const PhysicsCarPart*   parts      [[buffer(22)]],
                                  device PhysicsCarPair*         pairs      [[buffer(24)]],
                                  device uint4*                  islands    [[buffer(25)]],
                                  device uint*                   islandCars [[buffer(26)]],
                                  device uint*                   args       [[buffer(27)]],
                                  constant uint4&                info       [[buffer(30)]],
                                  uint t [[thread_position_in_grid]])
{
    if (t != 0) return;
    uint n = min(info.x, 32u), found = 0;
    ulong used[32];
    uint root[32];
    for (uint c = 0; c < n; ++c) { used[c] = 0; root[c] = c; cars[c].flags &= ~PHYS_CAR_PAIRED; }
    thread PhysicsCarPair list[96];
    for (uint a = 0; a < n; ++a) {
        PhysicsCar s = cars[a];
        bool off = false;
        for (int k = s.firstPart; k < s.firstPart + s.partCount; ++k) off = off || (parts[k].flags & PHYS_PART_OFF) != 0;
        for (uint b = off ? a : a + 1; b < n && found < 96; ++b) {
            PhysicsCar o = cars[b];
            if (b != a && !(all(s.lo.xyz <= o.hi.xyz) && all(o.lo.xyz <= s.hi.xyz))) continue;
            ulong free = ~(used[a] | used[b]);
            if (free == 0) continue;
            uint colour = ctz(free);
            used[a] |= 1ul << colour;
            used[b] |= 1ul << colour;
            list[found++] = {a, b, colour, 0u};
            uint ra = a, rb = b;
            while (root[ra] != ra) ra = root[ra];
            while (root[rb] != rb) rb = root[rb];
            if (ra != rb) root[max(ra, rb)] = min(ra, rb);
        }
    }
    // An asleep car that an awake one comes up to wakes, with its wheels.
    for (uint k = 0; k < found; ++k) {
        uint a = list[k].a, b = list[k].b;
        if (a == b) continue;
        bool sa = (cars[a].flags & PHYS_CAR_ASLEEP) != 0, sb = (cars[b].flags & PHYS_CAR_ASLEEP) != 0;
        if (sa == sb) continue;
        uint c = sa ? a : b;
        cars[c].flags = (cars[c].flags & ~PHYS_CAR_ASLEEP) | PHYS_CAR_AWAKE;
        cars[c].still = 0.0f;
        for (int w = cars[c].firstWheel; w < cars[c].firstWheel + cars[c].wheelCount; ++w) {
            if ((wheels[w].flags & PHYS_WHEEL_OFF) != 0) continue;
            bodies[wheels[w].body].info.y &= ~PHYS_ASLEEP;
            bodies[wheels[w].body].prevPosition.w = 0.0f;
        }
    }
    // The islands, in the order of their first car; each one's pairs by colour, then cars.
    uint islandCount = 0, pairsOut = 0, carsOut = 0;
    for (uint r = 0; r < n; ++r) {
        uint first = pairsOut;
        for (uint colour = 0; colour < 64 && pairsOut - first < found; ++colour) {
            for (uint k = 0; k < found; ++k) {
                uint ra = list[k].a;
                while (root[ra] != ra) ra = root[ra];
                if (ra == r && list[k].colour == colour) pairs[pairsOut++] = list[k];
            }
        }
        if (pairsOut == first) continue;
        uint firstCar = carsOut;
        for (uint c = 0; c < n; ++c) {
            uint rc = c;
            while (root[rc] != rc) rc = root[rc];
            bool inPair = false;
            for (uint k = first; k < pairsOut && !inPair; ++k) inPair = pairs[k].a == c || pairs[k].b == c;
            if (rc != r || !inPair) continue;
            islandCars[carsOut++] = c;
            cars[c].flags |= PHYS_CAR_PAIRED;
        }
        islands[islandCount++] = uint4(first, pairsOut - first, firstCar, carsOut - firstCar);
    }
    args[0] = islandCount;
    args[1] = 1;
    args[2] = 1;
}

inline int3 physGridKey(float3 x) { return int3(floor(x / 0.5f)); }   // CarSystem.gridCell
inline uint physGridBucket(int3 c) { return uint((c.x * 73856093) ^ (c.y * 19349663) ^ (c.z * 83492791)) & 1023u; }   // CarSystem.gridBuckets
constant uint PHYS_GRID_CELLS = 48;       // CarSystem.gridCells
constant float PHYS_CAR_SKIN = 0.02f, PHYS_CAR_REACH = 0.08f, PHYS_CAR_FRICTION = 0.5f;   // CarSolver.carSkin, carReach, carFriction

// CarSolver.closestWeights (Ericson's closest point on a triangle, its regions' weights).
inline float3 physClosestWeights(float3 p, float3 a, float3 b, float3 c) {
    float3 ab = b - a, ac = c - a, ap = p - a;
    float d1 = dot(ab, ap), d2 = dot(ac, ap);
    if (d1 <= 0.0f && d2 <= 0.0f) return float3(1, 0, 0);
    float3 bp = p - b;
    float d3 = dot(ab, bp), d4 = dot(ac, bp);
    if (d3 >= 0.0f && d4 <= d3) return float3(0, 1, 0);
    float vc = d1 * d4 - d3 * d2;
    if (vc <= 0.0f && d1 >= 0.0f && d3 <= 0.0f) { float v = d1 / (d1 - d3); return float3(1 - v, v, 0); }
    float3 cp = p - c;
    float d5 = dot(ab, cp), d6 = dot(ac, cp);
    if (d6 >= 0.0f && d5 <= d6) return float3(0, 0, 1);
    float vb = d5 * d2 - d1 * d6;
    if (vb <= 0.0f && d2 >= 0.0f && d6 <= 0.0f) { float v = d2 / (d2 - d6); return float3(1 - v, 0, v); }
    float va = d3 * d6 - d5 * d4;
    if (va <= 0.0f && d4 - d3 >= 0.0f && d5 - d6 >= 0.0f) { float v = (d4 - d3) / ((d4 - d3) + (d5 - d6)); return float3(0, 1 - v, v); }
    float denom = 1.0f / (va + vb + vc), v = vb * denom, u = vc * denom;
    return float3(1 - v - u, v, u);
}

// CarSolver.nodeDepth: how deep node x (prev: where it was) is in triangle tri: 0 when they don't meet.
inline float physNodeDepth(PhysicsParticle node, uint4 tri, device const PhysicsParticle* q) {
    float3 x = node.position.xyz, xa = q[tri.x].position.xyz, xb = q[tri.y].position.xyz, xc = q[tri.z].position.xyz;
    float3 normal = cross(xb - xa, xc - xa);
    float area = length(normal);
    if (!(area > 1e-8f)) return 0.0f;
    float3 w = physClosestWeights(x, xa, xb, xc);
    float distance = length(x - (xa * w.x + xb * w.y + xc * w.z)), side = dot(x - xa, normal / area);
    if (side >= 0.0f) return max(PHYS_CAR_SKIN - distance, 0.0f);
    if (!(distance <= -side + 1e-4f) || !(-side < PHYS_CAR_REACH)) return 0.0f;
    float3 pa = q[tri.x].prevPosition.xyz, pb = q[tri.y].prevPosition.xyz, pc = q[tri.z].prevPosition.xyz;
    return dot(node.prevPosition.xyz - pa, cross(pb - pa, pc - pa)) > 0.0f ? PHYS_CAR_SKIN - side : 0.0f;
}

inline void physAddDelta(device atomic_int* d, uint i, float3 v) {
    int3 f = int3(round(v * PHYS_CAR_FIXED));
    atomic_fetch_add_explicit(d + 4 * i, f.x, memory_order_relaxed);
    atomic_fetch_add_explicit(d + 4 * i + 1, f.y, memory_order_relaxed);
    atomic_fetch_add_explicit(d + 4 * i + 2, f.z, memory_order_relaxed);
    atomic_fetch_add_explicit(d + 4 * i + 3, 1, memory_order_relaxed);
}

// After a paired car's substep (physicsCarSubstepsKernel): its island's cars against each other, and a car's parts off
// against the rest of it (CarSolver.gridCar, meet, nodesAgainst, nodeTriangle). A threadgroup an island: each of its
// cars' hull triangles hashed into cells; then its pairs a colour at a time, each pair's cars' nodes against the other's
// triangles (which first turns about each substep), the deepest each meets pushing the node out and the triangle's
// nodes back by their masses. The pushes are summed (in fixed point) and each node moved by their mean, its speed with
// it, after each direction: what the CPU does one node after another, side by side, in no order that changes. Each
// push is equal and opposite (what the cars carry is kept), its nodes' masses split among the pushes they took the pass
// before (`splits`: a node many triangles push back counts as that many times as heavy), the pushes on a node summed.
kernel void physicsCarMeetKernel(constant PhysicsParams&        p          [[buffer(0)]],
                                 device const PhysicsCar*       cars       [[buffer(1)]],
                                 device const uint4*            triangles  [[buffer(2)]],
                                 device const uchar*            nodeParts  [[buffer(3)]],
                                 device atomic_uint*            starts     [[buffer(4)]],   // per car, its buckets' starts (+1)
                                 device atomic_uint*            cursors    [[buffer(5)]],   // per car, its buckets' fill
                                 device uint*                   items      [[buffer(6)]],   // per triangle, its cells' (PHYS_GRID_CELLS)
                                 device PhysicsParticle*        q          [[buffer(12)]],
                                 device float2*                 wear       [[buffer(19)]],
                                 device atomic_int*             deltas     [[buffer(20)]],   // per particle
                                 constant PhysicsGroup&         run        [[buffer(21)]],
                                 device const PhysicsCarPart*   parts      [[buffer(22)]],
                                 device uint*                   partWake   [[buffer(23)]],
                                 device const PhysicsCarPair*   pairs      [[buffer(24)]],
                                 device const uint4*            islands    [[buffer(25)]],
                                 device const uint*             islandCars [[buffer(26)]],
                                 device float*                  splits     [[buffer(27)]],   // per particle
                                 uint island [[threadgroup_position_in_grid]],
                                 uint t      [[thread_index_in_threadgroup]],
                                 uint width  [[threads_per_threadgroup]])
{
    threadgroup uint scan[1025];
    uint4 is = islands[island];
    float h = p.gravity.w;
    // Each car's triangles into its hash (two passes: counted into their buckets, then placed).
    for (uint ci = is.z; ci < is.z + is.w; ++ci) {
        uint c = islandCars[ci];
        PhysicsCar s = cars[c];
        device atomic_uint* start = starts + c * 1025, *cursor = cursors + c * 1024;
        device uint* item = items + uint(s.firstTriangle) * PHYS_GRID_CELLS;
        for (uint k = t; k < 1025; k += width) atomic_store_explicit(&start[k], 0u, memory_order_relaxed);
        threadgroup_barrier(mem_flags::mem_device);
        for (uint pass = 0; pass < 2; ++pass) {
            for (int tri = s.firstTriangle + int(t); tri < s.firstTriangle + s.triangleCount; tri += int(width)) {
                uint4 tr = triangles[tri];
                float3 pa = q[tr.x].position.xyz, pb = q[tr.y].position.xyz, pc = q[tr.z].position.xyz;
                int3 c0 = physGridKey(min(min(pa, pb), pc) - PHYS_CAR_REACH), c1 = physGridKey(max(max(pa, pb), pc) + PHYS_CAR_REACH);
                uint seen[PHYS_GRID_CELLS];
                uint m = 0;
                for (int z = c0.z; z <= c1.z; ++z) for (int y = c0.y; y <= c1.y; ++y) for (int x = c0.x; x <= c1.x && m < PHYS_GRID_CELLS; ++x) {
                    uint k = physGridBucket(int3(x, y, z));
                    bool known = false;
                    for (uint j = 0; j < m; ++j) known = known || seen[j] == k;
                    if (known) continue;
                    seen[m++] = k;
                    if (pass == 0) atomic_fetch_add_explicit(&start[k + 1], 1u, memory_order_relaxed);
                    else item[atomic_fetch_add_explicit(&cursor[k], 1u, memory_order_relaxed)] = uint(tri);
                }
            }
            threadgroup_barrier(mem_flags::mem_device);
            if (pass == 0) {
                // The counts made starts (read side by side, added up by one thread in threadgroup memory), and the fill
                // cursors at them.
                for (uint k = t; k < 1024; k += width) scan[k + 1] = atomic_load_explicit(&start[k + 1], memory_order_relaxed);
                threadgroup_barrier(mem_flags::mem_threadgroup);
                if (t == 0) {
                    scan[0] = 0;
                    for (uint k = 1; k <= 1024; ++k) scan[k] += scan[k - 1];
                }
                threadgroup_barrier(mem_flags::mem_threadgroup);
                for (uint k = t; k < 1025; k += width) {
                    atomic_store_explicit(&start[k], scan[k], memory_order_relaxed);
                    if (k < 1024) atomic_store_explicit(&cursor[k], scan[k], memory_order_relaxed);
                }
                threadgroup_barrier(mem_flags::mem_device);
            }
        }
    }
    // The pairs, a colour at a time; each pair both ways (a car with itself: its parts off against the rest).
    uint k = is.x, end = is.x + is.y;
    while (k < end) {
        uint colour = pairs[k].colour, last = k;
        while (last < end && pairs[last].colour == colour) ++last;
        for (uint way = 0; way < 2; ++way) {
            for (uint m = k; m < last; ++m) {
                PhysicsCarPair pr = pairs[m];
                bool own = pr.a == pr.b;
                if (own && way == 1) continue;
                bool flip = ((run.first & 1u) != 0) != (way == 1);
                uint nc = flip ? pr.b : pr.a, tc = flip ? pr.a : pr.b;
                PhysicsCar sn = cars[nc], st = cars[tc];
                device const atomic_uint* start = starts + tc * 1025;
                device const uint* item = items + uint(st.firstTriangle) * PHYS_GRID_CELLS;
                for (int i = sn.firstNode + int(t); i < sn.firstNode + sn.nodeCount; i += int(width)) {
                    PhysicsParticle node = q[i];
                    float3 x = node.position.xyz;
                    if (any(x < st.lo.xyz) || any(x > st.hi.xyz)) continue;
                    int nodePart = 0;
                    bool nodeOff = false;
                    if (own) {
                        nodePart = int(nodeParts[i]);
                        nodeOff = nodePart > 0 && (parts[sn.firstPart + nodePart - 1].flags & PHYS_PART_OFF) != 0;
                    }
                    uint bucket = physGridBucket(physGridKey(x));
                    uint from = atomic_load_explicit(&start[bucket], memory_order_relaxed), to = atomic_load_explicit(&start[bucket + 1], memory_order_relaxed);
                    int deepest = -1;
                    float most = 0.0f;
                    for (uint e = from; e < to; ++e) {
                        uint tri = item[e];
                        uint4 tr = triangles[tri];
                        if (own) {
                            int triPart = int(tr.w);
                            if (triPart == nodePart) continue;
                            if (!nodeOff && (triPart == 0 || (parts[st.firstPart + triPart - 1].flags & PHYS_PART_OFF) == 0)) continue;
                        }
                        float depth = physNodeDepth(node, tr, q);
                        // (The deepest; of equals, the first triangle: in no order the hash's filling left.)
                        if (depth > most || (depth == most && depth > 0.0f && int(tri) < deepest)) { deepest = int(tri); most = depth; }
                    }
                    if (deepest < 0) continue;
                    // CarSolver.nodeTriangle.
                    uint4 tr = triangles[deepest];
                    PhysicsParticle qa = q[tr.x], qb = q[tr.y], qc = q[tr.z];
                    float3 xa = qa.position.xyz, xb = qb.position.xyz, xc = qc.position.xyz;
                    float3 normal = cross(xb - xa, xc - xa);
                    float area = length(normal);
                    if (!(area > 1e-8f)) continue;
                    normal /= area;
                    float3 wt = physClosestWeights(x, xa, xb, xc);
                    float3 point = xa * wt.x + xb * wt.y + xc * wt.z, apart = x - point;
                    float distance = length(apart), side = dot(x - xa, normal);
                    float3 nrm = normal;
                    float depth;
                    if (side >= 0.0f) {
                        if (!(distance < PHYS_CAR_SKIN)) continue;
                        if (distance > 1e-6f) nrm = apart / distance;
                        depth = PHYS_CAR_SKIN - distance;
                    } else {
                        if (!(distance <= -side + 1e-4f) || !(-side < PHYS_CAR_REACH)) continue;
                        float3 pa = qa.prevPosition.xyz, pb = qb.prevPosition.xyz, pc = qc.prevPosition.xyz;
                        if (!(dot(node.prevPosition.xyz - pa, cross(pb - pa, pc - pa)) > 0.0f)) continue;
                        depth = PHYS_CAR_SKIN - side;
                    }
                    float wn = node.prevPosition.w, wa = qa.prevPosition.w, wb = qb.prevPosition.w, wc = qc.prevPosition.w;
                    float kn = max(splits[i], 1.0f), ka = max(splits[tr.x], 1.0f), kb = max(splits[tr.y], 1.0f), kc = max(splits[tr.z], 1.0f);
                    float weight = wn * kn + wt.x * wt.x * wa * ka + wt.y * wt.y * wb * kb + wt.z * wt.z * wc * kc;
                    if (!(weight > 0.0f)) continue;
                    float3 before = qa.prevPosition.xyz * wt.x + qb.prevPosition.xyz * wt.y + qc.prevPosition.xyz * wt.z;
                    float3 moved = (x - node.prevPosition.xyz) - (point - before);
                    float overlap = min(depth, max(-dot(moved, nrm), 0.0f) + PHYS_PUSH_SPEED * h);
                    if (!(overlap > 0.0f)) continue;
                    float3 push = physParticlePush(nrm, overlap, moved, PHYS_CAR_FRICTION) / weight;
                    physAddDelta(deltas, uint(i), push * wn);
                    physAddDelta(deltas, tr.x, -push * (wt.x * wa));
                    physAddDelta(deltas, tr.y, -push * (wt.y * wb));
                    physAddDelta(deltas, tr.z, -push * (wt.z * wc));
                    wear[i] += physCarSliding(moved, nrm, h);
                    // A part frozen where it lies, met: woken next step (physicsCarBeginKernel).
                    if (wa == 0.0f || wb == 0.0f || wc == 0.0f) {
                        int part = int(nodeParts[tr.x]);
                        if (part > 0) partWake[st.firstPart + part - 1] = 1u;
                    }
                }
            }
            threadgroup_barrier(mem_flags::mem_device);
            // Each node moved by its pushes' sum, its speed with it; how many it took, its mass's split next pass.
            for (uint m = k; m < last; ++m) {
                PhysicsCarPair pr = pairs[m];
                for (uint e = 0; e < (pr.a == pr.b ? 1u : 2u); ++e) {
                    PhysicsCar sc = cars[e == 0 ? pr.a : pr.b];
                    for (int i = sc.firstNode + int(t); i < sc.firstNode + sc.nodeCount; i += int(width)) {
                        int count = atomic_load_explicit(deltas + 4 * i + 3, memory_order_relaxed);
                        splits[i] = float(count);
                        if (count == 0) continue;
                        float3 d = float3(atomic_load_explicit(deltas + 4 * i, memory_order_relaxed), atomic_load_explicit(deltas + 4 * i + 1, memory_order_relaxed),
                                          atomic_load_explicit(deltas + 4 * i + 2, memory_order_relaxed)) / PHYS_CAR_FIXED;
                        for (uint f = 0; f < 4; ++f) atomic_store_explicit(deltas + 4 * i + f, 0, memory_order_relaxed);
                        q[i].position.xyz += d;
                        q[i].velocity.xyz += d / h;
                    }
                }
            }
            threadgroup_barrier(mem_flags::mem_device);
        }
        k = last;
    }
}

// After a group of the cars' substeps, before the world's: what they did to each body (physCarNode, physCarTyre) — its
// pushes' sum as a shove and the speed it stands for (each a substep's, as the CPU shoves it each substep), its tyres'
// kicks as a speed — and how many pushes a substep it took (the next group's mass splitting). A thread a body.
kernel void physicsCarBodiesKernel(device PhysicsBody*     bodies [[buffer(13)]],
                                   constant PhysicsGroup&  run    [[buffer(21)]],
                                   device atomic_int*      acc    [[buffer(22)]],
                                   device float*           shares [[buffer(23)]],
                                   constant PhysicsParams& p      [[buffer(0)]],
                                   constant uint4&         info   [[buffer(30)]],
                                   uint j [[thread_position_in_grid]])
{
    if (j >= info.z) return;
    device atomic_int* a = acc + j * PHYS_BODY_WORDS;
    int pushes = atomic_load_explicit(a + PHYS_ACC_PUSHES, memory_order_relaxed), kicks = atomic_load_explicit(a + PHYS_ACC_KICKS, memory_order_relaxed);
    float n = float(max(run.count, 1u));
    shares[j] = float(pushes) / n;
    if (pushes == 0 && kicks == 0) return;
    PhysicsBody b = bodies[j];
    b.info.y &= ~PHYS_ASLEEP;
    b.prevPosition.w = 0.0f;
    if (b.position.w > 0.0f) {
        float h = p.gravity.w;
        if (pushes > 0) {
            float3 dx = physFixed3(a + PHYS_ACC_PUSH, PHYS_PUSH_FIXED) * b.position.w;
            float3 turn = physInvInertia(b.rotation, b.invInertia.xyz, physFixed3(a + PHYS_ACC_PUSH_TWIST, PHYS_PUSH_FIXED));
            b.position.xyz += dx;
            b.rotation = physTurn(b.rotation, turn);
            b.velocity.xyz += dx / h;   // (as the CPU's shove each substep: its velocity the shove over a substep)
            b.angular.xyz += turn / h;
        }
        if (kicks > 0) {
            b.velocity.xyz += physFixed3(a + PHYS_ACC_KICK, PHYS_KICK_FIXED) * b.position.w;
            b.angular.xyz += physInvInertia(b.rotation, b.invInertia.xyz, physFixed3(a + PHYS_ACC_KICK_TWIST, PHYS_KICK_FIXED));
        }
    }
    bodies[j] = b;
    for (uint k = 0; k < PHYS_ACC_KNOCK; ++k) atomic_store_explicit(a + k, 0, memory_order_relaxed);
}

// Before the fractured objects' verdict: the cars' knocks on each piece this step, into its strain (PhysicsWorld.strike).
kernel void physicsCarStrikesKernel(device atomic_int*            acc   [[buffer(22)]],
                                    device PhysicsFractureState*  state [[buffer(24)]],
                                    constant uint4&               info  [[buffer(30)]],
                                    uint j [[thread_position_in_grid]])
{
    if (j >= info.z) return;
    device atomic_int* a = acc + j * PHYS_BODY_WORDS;
    float impulse = float(atomic_load_explicit(a + PHYS_ACC_KNOCK, memory_order_relaxed)) / PHYS_KNOCK_FIXED;
    if (!(impulse > 0.0f)) return;
    physStrike(state[j], physFixed3(a + PHYS_ACC_KNOCK_POINT, PHYS_POINT_FIXED) / impulse,
               physDirection(physFixed3(a + PHYS_ACC_KNOCK_PUSH, PHYS_KNOCK_FIXED)), impulse);
    for (uint k = PHYS_ACC_KNOCK; k < PHYS_ACC_HITS; ++k) atomic_store_explicit(a + k, 0, memory_order_relaxed);
}

// After the fractured objects' verdict (PhysicsWorld.carsGiveWay): a car whose knocks broke a piece or freed it gets back
// what it lost this step, less what breaking them took (their thresholds). A threadgroup a car; its sums in an order
// that is always the same.
kernel void physicsCarGiveWayKernel(device PhysicsCar*                  cars   [[buffer(1)]],
                                    device PhysicsCarWheel*             wheels [[buffer(7)]],
                                    device PhysicsParticle*             q      [[buffer(12)]],
                                    device PhysicsBody*                 bodies [[buffer(13)]],
                                    device atomic_int*                  acc    [[buffer(22)]],
                                    device const PhysicsFractureState*  state  [[buffer(24)]],
                                    device const PhysicsFractureNode*   nodes  [[buffer(25)]],
                                    constant uint4&                     info   [[buffer(30)]],
                                    uint car   [[threadgroup_position_in_grid]],
                                    uint t     [[thread_index_in_threadgroup]],
                                    uint width [[threads_per_threadgroup]],
                                    uint lane  [[thread_index_in_simdgroup]],
                                    uint group [[simdgroup_index_in_threadgroup]],
                                    uint groups [[simdgroups_per_threadgroup]])
{
    threadgroup float4 sums[32];
    PhysicsCar s = cars[car];
    uint bit = 1u << car;
    // What it broke or freed this step, and what that took.
    float spent = 0.0f, gave = 0.0f;
    for (uint j = t; j < info.z; j += width) {
        device atomic_uint* hits = (device atomic_uint*)(acc + j * PHYS_BODY_WORDS + PHYS_ACC_HITS);
        if ((atomic_load_explicit(hits, memory_order_relaxed) & bit) == 0) continue;
        atomic_fetch_and_explicit(hits, ~bit, memory_order_relaxed);
        float verdict = state[j].strain.w;
        if (verdict == 0.0f) continue;
        gave = 1.0f;
        spent += verdict == 1.0f ? nodes[j].offset.w : nodes[j].extra.y;
    }
    // Its momentum now.
    float3 now = float3(0.0f);
    for (int i = s.firstNode + int(t); i < s.firstNode + s.nodeCount; i += int(width)) {
        if (q[i].prevPosition.w > 0.0f) now += q[i].velocity.xyz / q[i].prevPosition.w;
    }
    if (int(t) < s.wheelCount) {
        PhysicsCarWheel w = wheels[s.firstWheel + int(t)];
        float inverse = (w.flags & PHYS_WHEEL_OFF) != 0 ? bodies[w.body].position.w : w.inverseMass;
        if (inverse > 0.0f) now += bodies[w.body].velocity.xyz / inverse;
    }
    float4 mine = float4(now, spent);
    mine = simd_sum(mine);
    gave = simd_max(gave);
    if (lane == 0) sums[group] = float4(mine.xyz, mine.w + 1e9f * gave);   // (gave: past any threshold's sum)
    threadgroup_barrier(mem_flags::mem_threadgroup);
    // (Every thread sums the groups' sums, in their order: the same numbers in each.)
    float4 total = float4(0.0f);
    bool any = false;
    for (uint g = 0; g < groups; ++g) {
        float4 x = sums[g];
        if (x.w >= 1e9f) { any = true; x.w -= 1e9f; }
        total += x;
    }
    float3 lost = s.momentum.xyz - total.xyz;
    float l = length(lost), mass = s.lo.w;
    if (!(any && l > total.w && mass > 0.0f)) return;
    float3 d = lost / l * ((l - total.w) / mass);
    for (int i = s.firstNode + int(t); i < s.firstNode + s.nodeCount; i += int(width)) {
        if (q[i].prevPosition.w > 0.0f) q[i].velocity.xyz += d;
    }
    if (int(t) < s.wheelCount) bodies[wheels[s.firstWheel + int(t)].body].velocity.xyz += d;
}

// Back to the start (a replay): the cars' state as built (`initial`: their words one after another, as `live`'s), the
// steps' sums at 0. `counts`: x = the words to copy, y = the words to clear.
kernel void physicsCarResetKernel(device const uint* initial [[buffer(1)]],
                                  device uint*       live    [[buffer(2)]],
                                  device uint*       cleared [[buffer(3)]],
                                  constant uint2&    counts  [[buffer(4)]],
                                  uint t [[thread_position_in_grid]],
                                  uint width [[threads_per_grid]])
{
    for (uint k = t; k < counts.x; k += width) live[k] = initial[k];
    for (uint k = t; k < counts.y; k += width) cleared[k] = 0u;
}
