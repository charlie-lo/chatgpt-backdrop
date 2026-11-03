import Foundation

@main
struct CDPClientTests {
    @MainActor
    static func main() async throws {
        let arguments = CommandLine.arguments
        let offline = arguments.contains("--offline")
        var port = 45678
        if !offline {
            guard let flag = arguments.firstIndex(of: "--port-file"), flag + 1 < arguments.count,
                  let portValue = Int(try String(contentsOfFile: arguments[flag + 1], encoding: .utf8)) else {
                throw NSError(domain: "TestUsage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Use Tests/run.sh, or pass --port-file PATH."])
            }
            port = portValue
        }
        func assert(_ condition: @autoclosure () -> Bool, _ name: String) throws {
            guard condition() else { throw NSError(domain: "TestFailure", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
            print("PASS \(name)")
        }
        for endpoint in ["ws://example.org:\(port)/devtools/page/a", "ws://127.0.0.1:1/devtools/page/a", "wss://127.0.0.1:\(port)/devtools/page/a", "ws://user:pass@127.0.0.1:\(port)/devtools/page/a", "ws://127.0.0.1:\(port)/other"] {
            let target = DebugTarget(id: "x", type: "page", title: "", url: "", webSocketDebuggerUrl: endpoint)
            do {
                _ = try CDPClient.validatedWebSocketURL(target: target, port: port)
                throw NSError(domain: "TestFailure", code: 1)
            } catch is CDPError { print("PASS rejected nonlocal or unexpected endpoint") }
        }
        do {
            _ = try await CDPClient.discover(port: 80)
            throw NSError(domain: "TestFailure", code: 1)
        } catch CDPError.invalidPort { print("PASS invalid discovery port") }

        if offline {
            print("All offline endpoint validation tests passed.")
            return
        }

        let targets = try await CDPClient.discover(port: port)
        try assert(targets.count == 1, "target discovery")
        let client = CDPClient()
        try await client.connect(target: targets[0], port: port)
        try assert(client.isConnected, "websocket ping handshake")
        let echo = try await client.command(method: "Test.echo", params: ["value": "fixture"])
        try assert(echo["value"] as? String == "fixture", "request and reply")

        async let one = client.command(method: "Test.reverse", params: ["value": 1])
        async let two = client.command(method: "Test.reverse", params: ["value": 2])
        let (first, second) = try await (one, two)
        try assert(first["value"] as? Int == 1 && second["value"] as? Int == 2, "out-of-order replies and ignored events")
        do {
            _ = try await client.command(method: "Test.protocolError")
            throw NSError(domain: "TestFailure", code: 1)
        } catch CDPError.protocolFailure { print("PASS protocol errors surface") }
        do {
            _ = try await client.command(method: "Test.runtimeError")
            throw NSError(domain: "TestFailure", code: 1)
        } catch CDPError.runtimeException { print("PASS JavaScript errors surface") }

        let cancelled = Task { try await client.command(method: "Test.silent") }
        await Task.yield()
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            throw NSError(domain: "TestFailure", code: 1)
        } catch is CancellationError { print("PASS cancelled commands complete") }
        let start = Date()
        do {
            _ = try await client.command(method: "Test.silent")
            throw NSError(domain: "TestFailure", code: 1)
        } catch CDPError.timedOut {
            try assert(Date().timeIntervalSince(start) < 6.5, "bounded command timeout")
        }

        let pending = Task { try await client.command(method: "Test.silent") }
        await Task.yield()
        client.disconnect()
        do {
            _ = try await pending.value
            throw NSError(domain: "TestFailure", code: 1)
        } catch CDPError.disconnected { print("PASS disconnect resolves pending command") }
        try assert(!client.isConnected, "disconnected state")
        try await client.connect(target: targets[0], port: port)
        try assert(client.isConnected, "reconnect after disconnect")
        client.disconnect()
        print("All CDP transport tests passed.")
    }
}
