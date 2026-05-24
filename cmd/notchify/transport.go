package main

import (
	"errors"
	"net"
	"os"
	"strconv"
	"time"
)

const (
	socketPath           = "/tmp/notchify.sock"
	defaultTCPHost       = "127.0.0.1"
	defaultTCPPort       = 43187
	dialTimeout          = 500 * time.Millisecond
	defaultTCPDrainDelay = time.Second
	socketUnreachableMsg = "connect(/tmp/notchify.sock) failed: is notchify-daemon running?"
)

// sendToDaemon writes the payload to the daemon's Unix socket, falling
// back to a loopback-TCP listener when requested (used for sandboxes /
// VMs that cannot mount the host socket). Commands (`--daemon quit`)
// pass allowTCPFallback=false: the daemon only accepts commands on the
// trusted socket transport.
func sendToDaemon(data []byte, allowTCPFallback bool) error {
	if err := sendUnix(data, socketPath); err == nil {
		return nil
	}
	if !allowTCPFallback {
		return errors.New("unix socket unreachable")
	}
	return sendTCP(data)
}

func sendUnix(data []byte, path string) error {
	conn, err := net.DialTimeout("unix", path, dialTimeout)
	if err != nil {
		return err
	}
	defer conn.Close()
	_, err = conn.Write(data)
	return err
}

// tcpDrainDelay returns how long sendTCP should hold the connection
// open after writing the payload, before closing.
//
// Why: the agentbox host-guest TCP relay (Gondolin tcp-map, similar
// proxies that translate a guest port to the host's loopback) needs
// the guest-side socket to stay open briefly so the relay finishes
// forwarding bytes to the host before the FIN propagates. Without
// this wait, the guest's write-then-immediate-close races the relay
// and the host daemon silently receives nothing. The prior Python
// shim used a 1s wait that we know works on the current Gondolin
// path, so we mirror that as the default. Local Unix-socket sends do
// not pay this cost; only TCP fallback callers do.
//
// Override via NOTCHIFY_TCP_DRAIN_DELAY (Go duration string, e.g.
// "200ms", "0s") to tune for a transport that doesn't need the
// drain. Negative values clamp to zero.
func tcpDrainDelay() time.Duration {
	value := os.Getenv("NOTCHIFY_TCP_DRAIN_DELAY")
	if value == "" {
		return defaultTCPDrainDelay
	}
	delay, err := time.ParseDuration(value)
	if err != nil {
		return defaultTCPDrainDelay
	}
	if delay < 0 {
		return 0
	}
	return delay
}

func sendTCP(data []byte) error {
	host := os.Getenv("NOTCHIFY_TCP_HOST")
	if host == "" {
		host = defaultTCPHost
	}
	port := defaultTCPPort
	if s := os.Getenv("NOTCHIFY_TCP_PORT"); s != "" {
		if p, err := strconv.Atoi(s); err == nil && p > 0 && p < 65536 {
			port = p
		}
	}
	conn, err := net.DialTimeout("tcp4", net.JoinHostPort(host, strconv.Itoa(port)), dialTimeout)
	if err != nil {
		return err
	}
	defer conn.Close()
	if _, err := conn.Write(data); err != nil {
		return err
	}
	// Keep the socket open briefly before the deferred Close so the
	// host-side TCP relay finishes forwarding. See tcpDrainDelay.
	time.Sleep(tcpDrainDelay())
	return nil
}
