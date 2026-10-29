# LiveRadar

A working answer to the question *"how would you show 50,000 aircraft on a map without lag?"*

LiveRadar is a small iOS app that draws **50,000–100,000 moving aircraft at full frame rate**. It's
fed by a mocked streaming backend shaped like a gRPC service, and the backend only sends what the
client can't predict on its own.

It includes a switch to a naive `MKAnnotation` implementation, so the difference can be seen live
rather than just described. Everything below was measured, not estimated, unless it says otherwise.

## Run it

```
open LiveRadar.xcodeproj        # Xcode 26+, iOS 17+ target
```

Pick an iPhone simulator or a device and run. There are no external dependencies. The backend is an
in-process mock, so it works offline.

```
cd Packages/FlightFeed && swift test   # codec, engine and mock-server tests (run on macOS)
```

Controls at the bottom of the app:

- **Aircraft**: 1k / 10k / 50k / 100k. Restarts the simulated sky.
- **Renderer**: Metal (the real one) or MKAnnotation (the naive baseline).
- **Viewport only**: the server streams only what's inside the visible area plus a margin, and sends
  add/remove diffs as you pan.
- **Adaptive**: the server forwards a report only when the client's own prediction would be more
  than 2 pt off on screen (see section 5). Turn it off to get every report.
- **Sim speed**: 1× is real time. 10× and 60× make movement visible at country zoom.

The HUD shows main-thread FPS, the worst frame time, feed throughput, records/s and decode and apply
cost per frame.

## Layout

```
LiveRadar/                     iOS app (SwiftUI shell, UIKit/MapKit/Metal inside)
  Map/AircraftRenderer.swift   instanced Metal renderer + CPU hit-testing
  Map/Shaders.metal            per-vertex dead reckoning, rotation, altitude colour
  Map/MapProjection.swift      MKMapView camera -> Mercator transform
  Map/AnnotationBaseline.swift the naive MKAnnotation version, for comparison
  Map/RadarMapView.swift       MKMapView + transparent MTKView overlay
  RadarViewModel.swift         wiring, stats, selection
Packages/FlightFeed/
  FlightFeed/                  client: wire model, codec, transport seam, ingest engine
  MockFlightServer/            fake backend: great-circle flights between ~80 airports
Proto/live_feed.proto          the contract a real gRPC service would expose
```

## Measured (iPhone 17 Pro simulator, iOS 26.4, Europe at about zoom 3.5, 10× sim speed)

| | MKAnnotation baseline | Metal (this app) |
|---|---|---|
| 1k aircraft | 50–90 ms main-thread time per 1 s update | 60 fps, 0 per-aircraft main-thread work |
| 10k aircraft | about 6.3 s main-thread stall per update | 60 fps |
| 50k aircraft | main thread frozen for more than 90 s (so the mode is capped at 10k) | 60 fps, worst frame 17 ms |

Feed at 50k, Release build, every report forwarded (Adaptive off):

| | Global | Viewport only |
|---|---|---|
| Aircraft held by the client | 50,000 | about 8,000 |
| Bandwidth | about 490 KB/s | about 60 KB/s |
| Records/s | about 27,000 | about 3,300 |
| Decode + apply per frame (off main) | 0.1 + 0.8 ms | 0.1 + 0.2 ms |

Adaptive updates (section 5), sustained averages over 5 minutes of feed time from the
`errorThresholdForwardsFewerReports` test (2k aircraft, 2 pt threshold, 10× speed):

| Client zoom | Every report | Adaptive | Reduction |
|---|---|---|---|
| 4 (continent) | 1,044 records/s | 119 records/s | about 9× |
| 8 (region) | 1,043 records/s | 123 records/s | about 8× |
| 12 (city) | 1,045 records/s | 225 records/s | about 4.6× |

In the app at 50k and continent zoom, a single HUD sample showed 588 → 23 KB/s. About half of what
remains at low zoom is the per-flight heartbeat. **Caveat:** mock flights are perfectly smooth great
circles. Real tracks have sensor noise, ATC vectors and holding patterns, so expect smaller savings
in production.

The simulator caps the display at 60 Hz, so 60 fps is the ceiling there. On a ProMotion device the
renderer asks for 120. Debug builds decode about 10× slower, which still stays off the main thread.

## Answer: "How do you show 50k annotations without lag?"

Short version: **don't use annotations.** Treat aircraft as data and draw them in one GPU draw call.
Keep the main thread out of the data path, and make the network send as little as possible.

### 1. Rendering: one instanced draw call, not 50k views

`MKAnnotationView` is a `UIView`. MapKit lays out, hit-tests and collision-checks every visible view
on the main thread, and every coordinate change goes through KVO. That is fine for hundreds of
annotations and falls apart at tens of thousands. Switch the app to *MKAnnotation* at 50k to see it.

Instead:

- The whole fleet is one buffer of 32-byte structs (`AircraftInstance`: Mercator position,
  velocity, heading, timestamp, altitude, id). 50k aircraft is 1.6 MB.
- One `drawPrimitives(... instanceCount: n)` draws every aircraft as a textured, rotated quad.
  GPUs are built for millions of vertices, and 300k is nothing.
- The map is still `MKMapView` (tiles and gestures). A transparent, touch-through `MTKView` sits on
  top. Each frame, the renderer reads the map's `visibleMapRect` and turns it into a 40-byte
  uniform block, so pan and zoom cost no per-aircraft CPU work.
- Precision: positions are float32 normalized Mercator, and the shader subtracts the camera centre
  before scaling, so the error stays at about 1 pt up to roughly zoom 16. That's plenty for traffic.
  Crossing the antimeridian is handled with `d.x -= rint(d.x)`.

### 2. Motion: decouple network rate from frame rate

Aircraft report about once per second, and the screen refreshes 60–120 times per second. Interpolating
on the CPU means touching 50k objects 120 times a second. Here the **vertex shader dead-reckons**:
`position + velocity * (now - timestamp)`, capped at 60 s. The CPU only touches an aircraft when a
new report arrives for it.

### 3. Threading: the main thread never sees the feed

```
transport ──frames──▶ LiveTrafficEngine (actor)            main thread
                       decode → apply to dense arrays  ──▶ RenderFeed (lock, versioned snapshot)
                                                            └─ renderer uploads only if version changed
```

- Decoding and applying run on an actor. Storage is dense parallel arrays plus an `id → slot` map.
  Removal swaps the last element into the hole, so the array can go to the GPU in a single memcpy.
- The hand-off is a versioned immutable snapshot behind an unfair lock. The renderer never waits on
  the engine, and the engine never waits on the renderer.
- A fresh `MTLBuffer` per upload (a few per second) avoids triple-buffering semaphores. In-flight
  command buffers keep the old buffer alive.

### 4. Network: snapshot + deltas, columnar, viewport-driven

My assumption about FR24 (not verified): unofficial community clients show a gRPC-web live-feed
endpoint that takes a bounding box. This mock is modelled on that:

- **Bidirectional stream.** The client opens with a `SubscribeRequest`. The server sends a
  **snapshot**, then **deltas** (`added` metadata once, `removed` ids, position columns). Static data
  such as callsign, type and route is never repeated in position updates.
- **The client can change the viewport mid-stream.** The server remembers what each client already
  knows and sends only what entered or left the view. Toggle *Viewport only* and watch KB/s drop.
- **Columnar, packed varints** (`PositionColumns`): ids are delta-coded, lat/lon are zigzag 1e-5°.
  That's about 19 bytes per record versus 24 fixed-width. It's honestly a modest win, and the large
  savings come from deltas and viewport filtering, not bit-packing. Next steps would be quantizing
  altitude to 25 ft (the ADS-B resolution) and sorting records spatially so lat/lon delta-code well.
- Each aircraft reports on its own 1–3 s cadence (like receivers do), so each 200 ms frame carries a
  rolling subset rather than a 50k burst.
- On disconnect, the engine reconnects with exponential backoff. The server always opens with a
  snapshot, so no reconciliation is needed.

### 5. Update frequency: send on prediction error, not on a timer

The client already dead-reckons every aircraft. So the server runs **the same prediction** per
client and forwards a report only when it matters (`MockFlightServer.Subscriber.needsUpdate`):

- the predicted position is off by more than **2 screen points at the client's zoom** (the client
  sends its zoom along with the viewport), or
- altitude changed by 500 ft or more (it drives colour and the detail card), or
- a per-flight heartbeat (27–45 s, staggered by id) keeps the client from extrapolating too long.

Speed alone doesn't decide the rate; **predictability** does. A jet in straight cruise barely needs
updates. A plane turning onto final needs them every second. Zoom also matters: at continent zoom,
1 km of error is sub-pixel. The wire protocol didn't change at all. The server just sends fewer
records.

### 6. Where I'd take this next

- **Better prediction, fewer corrections.** Straight-line dead reckoning misses every turn. Send the
  expected path once per flight (flight plan plus how the route is typically flown historically:
  departure and arrival procedures, the usual approach per runway) and have the client move the
  aircraft along it. The error threshold stays as the safety net for ATC vectors, holds,
  go-arounds and diversions, which are exactly the flights people watch. Estimated positions should
  look estimated.
- **Level of detail by zoom.** At continent zoom, 50k icons are mostly overdraw. Draw dots or a
  density layer when zoomed out, declutter to one aircraft per screen cell by priority, and let the
  server cap aircraft per tile (selected flight and filter matches first). The request already
  carries viewport and zoom, so this is a server-side change.
- **Map/overlay sync**: `MKMapView` and the Metal layer composite separately, so fast flings can show
  a one-frame offset. The full fix is drawing map tiles in the same Metal pass (a custom vector-tile
  renderer, or a Metal-based map SDK).
- **Hit-testing**: a linear scan over 50k on tap takes well under 1 ms. A uniform grid or quadtree
  only pays off for continuous hover or drag selection.
- **Trails** for the selected flight, using the same instancing approach with a line-strip buffer.
- **Real transport**: generate from `Proto/live_feed.proto` with grpc-swift 2 and implement
  `FeedTransport` with it. Nothing above that seam changes.
