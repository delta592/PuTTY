import PuttyBridge

@_cdecl("putty_bridge_swift_smoke")
public func puttyBridgeSwiftSmoke() -> Int32 {
    Int32(putty_bridge_version())
}
