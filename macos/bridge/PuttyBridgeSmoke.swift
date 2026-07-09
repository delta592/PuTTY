import PuttyBridge

@_cdecl("putty_bridge_swift_smoke")
public func puttyBridgeSwiftSmoke() -> Int32 {
    let api = putty_bridge_api_version()
    let platform = String(cString: putty_bridge_buildinfo_platform())
    guard api == Int32(PUTTY_BRIDGE_API_VERSION) else { return -1 }
    guard platform == "macOS (AppKit)" else { return -2 }
    return Int32(putty_bridge_version())
}
