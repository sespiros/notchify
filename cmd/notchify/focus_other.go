//go:build !darwin

package main

// introspectFocus is a no-op on non-darwin platforms. On Linux the
// CLI relies entirely on NOTCHIFY_FOCUS_* env vars populated by the
// sandbox launcher; there is no way to introspect a host-side macOS
// bundle from inside a Linux VM regardless.
func introspectFocus(_ *focusCapture) {}
