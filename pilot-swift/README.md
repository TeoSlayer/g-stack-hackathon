# Pilot Swift

A Swift package that lets iOS and macOS apps act as full
[Pilot Protocol](https://pilotprotocol.network/) nodes — registering,
handshaking with peers, and exchanging end-to-end-encrypted messages
— without needing a separate `pilot-daemon` process running on the
device.

```swift
import Pilot

let pilot = try Pilot.start(.init(
    dataDir: appSupport.appendingPathComponent("pilot"),
    socketPath: "p.sock"))

try pilot.handshake(peerID: 161006, justification: "hi")
try pilot.send(to: "0:0000.0002.74EE", port: 1001, data: Data("hello".utf8))
```

## What Pilot Protocol is

Pilot is an overlay network for AI agents and apps. Each node has an
Ed25519 identity, a virtual address (`N:NNNN.HHHH.LLLL` format), and
NAT-traversed encrypted tunnels (X25519 + AES-256-GCM) to its trusted
peers. A directory of 400+ public service agents covers live finance,
weather, transit, government data, dev metadata, and more — so any
node on the network can query them with a single command.

The canonical implementation is a Go daemon (`pilot-daemon`) that
runs as a long-lived process, opens a Unix-domain IPC socket
(`/tmp/pilot.sock`), and serves client SDKs (Python, Node) that
RPC into it. That model fits desktops and servers.

It doesn't fit iOS.

## How this builds on Pilot Protocol

iOS apps run in a single-process sandbox: no sibling daemon binary,
no system-wide IPC socket, no `launchd` to keep a side process
alive. To put a Pilot node on an iPhone, the daemon has to live
*inside* the app process.

This package does that. The pilot-daemon Go code is cross-compiled
to a static C library (`libPilot.a`) for three slices — iOS device,
iOS simulator (Apple Silicon), and macOS arm64 — bundled as
`Pilot.xcframework`, and exposed through a Swift API
(`Sources/Pilot/Pilot.swift`).

Key additions on top of the upstream protocol:

- **`PilotEmbeddedStart` / `PilotEmbeddedStop` C ABI** — boots the
  daemon's goroutines in the host process and opens an IPC socket
  inside the app sandbox. Pairs with the existing 46-function
  `Pilot*` C ABI that the Python and Node SDKs already use.
- **Sandbox-aware Unix socket handling** — Unix `sun_path` is 104
  bytes on darwin/ios, and iOS Application Support paths often
  exceed that on their own. `Pilot.start` chdir's into the data
  dir and uses a relative socket basename so the bind succeeds.
- **`Pilot.xcframework`** — three precompiled architecture slices
  (≈12 MB each), bundled with module map + headers so SwiftPM's
  `binaryTarget` and Xcode both resolve it without extra
  configuration.
- **Idiomatic Swift wrapper** — typed config, `Pilot.Error` cases,
  `Data` for payloads, `Datagram` struct for receive, automatic
  teardown in `deinit`. The raw C ABI is hidden.

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│ Your iOS app (Swift)                                       │
│   ┌──────────────────────────────────────────────────────┐ │
│   │ Pilot.swift  — idiomatic Swift API                   │ │
│   └────────────────────┬─────────────────────────────────┘ │
│                        │ C ABI (47 exported functions)     │
│   ┌────────────────────▼─────────────────────────────────┐ │
│   │ libPilot.a (cgo static archive, ~12 MB per slice)    │ │
│   │   • PilotEmbeddedStart / Stop  (daemon lifecycle)    │ │
│   │   • PilotConnect / Info / Health  (driver client)    │ │
│   │   • PilotHandshake / WaitForTrust / SendTo / RecvFrom│ │
│   │   • PilotNetwork* / PilotPolicy* / PilotManaged*     │ │
│   ├──────────────────────────────────────────────────────┤ │
│   │ embedded pilot-daemon (goroutines, in-process)       │ │
│   │   • Ed25519 identity, persistent in dataDir          │ │
│   │   • Registry RPC (length-prefixed JSON over TCP)     │ │
│   │   • Beacon NAT traversal + relay fallback            │ │
│   │   • Noise-style tunnel (X25519 + AES-256-GCM)        │ │
│   │   • Handshake state machine + trust persistence      │ │
│   │   • Unix-socket IPC inside the app sandbox           │ │
│   └──────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────┘
                              ↓ network
        ┌─────────────────────┴─────────────────────┐
        │ Pilot registry (34.71.57.205:9000)        │
        │ Pilot beacon   (34.71.57.205:9001)        │
        └────────────────────────────────────────────┘
```

## Quick start

Add the package to your app:

```swift
// Package.swift
.package(path: "../pilot-swift")
// or, when published:
// .package(url: "https://github.com/.../pilot-swift", from: "0.1.0")
```

Then in your app code:

```swift
import Pilot

let dataDir = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("pilot")

// Boot once at app launch.
let pilot = try Pilot.start(.init(
    dataDir: dataDir,
    socketPath: "p.sock",       // keep relative + short (sun_path ≤ 104 bytes)
    trustAutoApprove: false,
    keepaliveSeconds: 30
))

print("node_id=\(pilot.start.nodeID) addr=\(pilot.start.address)")

// Trust a peer and send a message.
try pilot.handshake(peerID: 161006, justification: "hello")
// Wait for the other side to approve — they'll do `pilotctl approve <your_id>`
// or have trust-auto-approve enabled.
Task {
    while !(try pilot.trustedPeers().contains(where: {
        ($0["node_id"] as? NSNumber)?.uint32Value == 161006 }))
    {
        try await Task.sleep(for: .seconds(2))
    }
    try pilot.send(to: "0:0000.0002.74EE", port: 1001,
                   data: Data("hello".utf8))
}

// Receive on a background task.
Task {
    while let dg = try? pilot.receive() {
        print("got \(dg.data.count) bytes from \(dg.srcAddr):\(dg.srcPort)")
    }
}

// On shutdown:
try pilot.stop()
```

## Running the smoke test

The `Examples/pilot-smoke-swift/` target proves the SDK works against
the live Pilot network. Three modes:

```sh
# Boot a simulator if you haven't.
xcrun simctl boot "iPhone 17"

scripts/run-smoke-sim.sh info               # boot, fetch Info+Health
scripts/run-smoke-sim.sh alice              # listen for one message
scripts/run-smoke-sim.sh bob <id> <addr>    # handshake + send to peer
```

`run-smoke-sim.sh` builds the smoke binary with `swiftc` targeted at
`arm64-apple-ios14.0-simulator`, links the simulator slice of
`Pilot.xcframework`, then spawns it inside the booted simulator
with `xcrun simctl spawn`. End-to-end test in one command, no
Xcode project required.

## Rebuilding `Pilot.xcframework` from source

The framework ships precompiled (~36 MB total across all three
slices). To rebuild — for example after updating the Go protocol
code — point at a clone of the pilotprotocol repo:

```sh
export PILOT_REPO=/path/to/pilotprotocol
scripts/build-xcframework.sh
```

If you have the repo cloned as a sibling of this one or at
`~/Development/web4` or `~/Development/pilotprotocol`, the script
finds it without needing `$PILOT_REPO`.

The script invokes `go build -buildmode=c-archive` for each target
SDK + arch, generates the C header + Clang module map per slice,
and bundles via `xcodebuild -create-xcframework`.

## Known constraints

- **One Pilot per process.** The embedded daemon is process-global —
  create a single `Pilot` at app launch and reuse it.
- **Socket path ≤ 100 bytes.** Pass a short *relative* basename;
  `Pilot.start` will `chdir(dataDir)` so the bind lands inside your
  sandbox.
- **iOS background suspension.** When iOS suspends your app, the
  embedded daemon pauses with it. The protocol's registry buffers
  incoming handshakes for a bounded time, so a foreground app on
  next launch will drain whatever queued. For always-on operation,
  drive the daemon from a `NEPacketTunnelProvider` extension
  (a v0.2 concern).
- **Identity at rest.** `identity.json` is currently plaintext
  inside the app sandbox. Sealing the Ed25519 key behind a
  Secure Enclave wrapping key is on the roadmap.
- **No `NetworkExtension` entitlement needed** for outbound traffic.
  iOS apps can open arbitrary outbound TCP/UDP to the public
  internet without special permission.

## Tested

- ✅ macOS arm64 (`swift build`, smoke `info` mode)
- ✅ iOS 26.5 simulator (iPhone 17), arm64 — full alice/bob
  smoke including handshake, encrypted tunnel, datagram delivery
- ✅ Cross-environment: Swift in iOS sim ↔ Go daemon on host
- ✅ Embedded SDK → live local pilot daemon — message routed via
  beacon relay, decrypted, and written to the host daemon's
  `~/.pilot/inbox/` as a TEXT frame, with ACK round-trip
- ⏳ Real iOS device (requires a developer account)

## License

AGPL-3.0-or-later, matching upstream Pilot Protocol.
