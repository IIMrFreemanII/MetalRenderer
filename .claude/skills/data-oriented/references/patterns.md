# Fast-subset patterns, from this repo

Each pattern is the shape of code that passes `Tools/perf/hotcalls.py`, with the place it lives.

## A loop over a class's array

`Scene` and the other systems are `final class`es holding arrays. Indexing them per element costs an exclusivity
check each time, and reading a field of a large element may copy all of it. Go through the buffer, with everything
else hoisted (`Scene.writeInstanceData`):

```swift
let meshCount = meshes.count                    // other properties: `let`s before the loop
instances.withUnsafeBufferPointer { inst in
    for i in moving {
        let mesh = inst[i].mesh                 // one field, no copy of the element
        out[i] = Record(transform: inst[i].transform, mesh: UInt32(mesh), …)
    }
}
```

The mutable form is `withUnsafeMutableBufferPointer`. Inside it, don't call a method of `self` that touches the same
array: that is an overlapping access and traps. Do the write through the buffer instead (`Scene.update`'s `move`
sets `transform` and `normalMatrix` itself rather than calling `setTransform`).

## In parts on every core

Each element is written by exactly one part. The buffer pointer is captured as a `let` (`Scene.update`, the crowd's
walkers):

```swift
let slots = crowd.slots                         // read-only inputs as locals
crowd.walkers.withUnsafeBufferPointer { walkers in
    instances.withUnsafeMutableBufferPointer { inst in
        let inst = inst, part = 8192
        DispatchQueue.concurrentPerform(iterations: (walkers.count + part - 1) / part) { k in
            for w in walkers[(k * part)..<min((k + 1) * part, walkers.count)] {
                inst[w.instance].transform.columns.3 = …   // each walker owns its instance
            }
        }
    }
}
```

For records indexed by a list, `SceneBuffers.inParts(list.count) { range in for k in range { write(list[k]) } }`. A
list under one part (16384) is a single iteration.

## A Metal object's ID or a resource list, asked once

`structure.gpuResourceID` is an Objective-C message, and `[parts] + structures` typed `[MTLResource]` checks each
element's protocol conformance. Make them once (`SceneBuffers.primitiveIDs`, `PlantTracing.resources(slot:)`):

```swift
private var declared: [Int: [MTLResource]] = [:]
private(set) var sets: [[MTLAccelerationStructure]] = [] { didSet { declared = [:] } }   // made again on a change

func resources(slot: Int) -> [MTLResource] {
    let set = set(slot: slot)
    if let made = declared[set] { return made }
    let made: [MTLResource] = [parts, cutouts] + sets[set].map { $0 as MTLResource }
    declared[set] = made
    return made
}
```

## Kinds without protocols

A few kinds that a loop treats differently: sort them into arrays once, and loop over each with its own code. The lights
say how they move (`Scene.LightMotion`: `.animated`, `.scaleOnly`, `.constant`). The scene keeps `animated.lights`
and `animated.scaledLights`, and the per-frame loop never asks a light what it is.

## Per-frame arrays without allocation

```swift
private var stage: [GPULight] = []              // sized once, when the scene is installed (Renderer.lightStage)
…
stage.withUnsafeMutableBufferPointer { s in for l in changing { s[l] = gpuLight(l) } }   // rewrite what changed
stage.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
```

Temporaries that must exist per frame are stored properties emptied with `removeAll(keepingCapacity: true)`.

## Structural changes between frames

Edits to the arrays (spawning, moving for good, removing) are collected and applied where the frame starts. Nothing
reorders an array while a loop or a GPU frame reads it: `Scene.moveInstances(_:record:)` collects
`instanceEdits`, and the renderer takes them with `takeInstanceEdits()`. A background job's results wait in VirtualBLAS's
`finished` until the render thread installs them, and replaced GPU resources wait in `retired` for
`maxFramesInFlight` frames.

## Finding a loop's name for hot-functions.txt

```bash
swift build -c release
python3 Tools/perf/hotcalls.py -v --list <(echo "Scene.update(time:dayTime:)")
```

That prints every function whose demangled name contains the text, with its runtime calls and (with `-v`) its other
calls. Copy the exact name of the clean loop into `Tools/perf/hot-functions.txt`.
