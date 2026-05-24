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
	time.Sleep(tcpDrainDelay())
	return nil
}
