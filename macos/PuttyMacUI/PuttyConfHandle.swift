import PuttyBridge

/**
 * Opaque configuration handle (`PuttyConf *` in C; the clang module does not
 * export the incomplete struct).
 *
 * Ownership: caller-owned. Create with `putty_conf_new` / cmdline parse;
 * free with `putty_conf_free` when done. `SessionWindowController.openNew`
 * takes ownership of the handle passed in and frees it after
 * `putty_bridge_termwin_open`.
 */
public typealias PuttyConfHandle = OpaquePointer
