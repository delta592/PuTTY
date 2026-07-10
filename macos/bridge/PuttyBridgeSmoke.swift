import PuttyBridge

@_cdecl("putty_bridge_swift_smoke")
public func puttyBridgeSwiftSmoke() -> Int32 {
    let api = putty_bridge_api_version()
    let platform = String(cString: putty_bridge_buildinfo_platform())
    guard api == Int32(PUTTY_BRIDGE_API_VERSION) else { return -1 }
    guard platform == "macOS (AppKit)" else { return -2 }
    guard putty_bridge_session_smoke() == 0 else { return -3 }
    guard putty_bridge_conf_smoke() == 0 else { return -4 }
    guard putty_bridge_eventloop_smoke() == 0 else { return -5 }
    guard putty_bridge_thread_smoke() == 0 else { return -6 }
    return Int32(putty_bridge_version())
}
