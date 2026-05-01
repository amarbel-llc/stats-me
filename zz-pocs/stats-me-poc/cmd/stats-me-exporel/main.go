// stats-me POC driver. Validates one hypothesis: Bun can run the
// upstream statsd/statsd stats.js daemon, listen on UDP, accept a
// counter packet, and emit a console-backend flush record.
//
// Hardcoded constants below; no flags, no env vars.
//
// Empirical finding from the spike: under Bun 1.3.11 on darwin,
// `dgram`'s `'listening'` event fires before the underlying receive
// path is fully wired. A single packet sent ~50ms after `bind()`
// returns gets dropped silently. Subsequent packets work. This driver
// spams a counter every 500ms for the whole flush window so the test
// is not sensitive to that startup race. Production stats-me clients
// are UDP-loss-tolerant by design and will retry naturally; the spike
// just makes the timing explicit.
package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	statsdPort     = 18125
	flushInterval  = 10000 // ms
	startupTimeout = 5 * time.Second
	flushTimeout   = 12 * time.Second
	startupNeedle  = "server is up"
	flushNeedle    = "foo" // counter we send; should appear in flush output
)

// Set via -ldflags -X at build time. The flake fills these in.
var (
	bunPath   = ""
	statsdSrc = ""
)

func main() {
	if err := run(); err != nil {
		log.Printf("FAIL: %v", err)
		os.Exit(1)
	}
	log.Print("PASS")
}

func run() error {
	if bunPath == "" || statsdSrc == "" {
		return fmt.Errorf("bunPath and statsdSrc must be set via -ldflags (got %q, %q)", bunPath, statsdSrc)
	}

	workDir, err := os.MkdirTemp("", "stats-me-poc-")
	if err != nil {
		return fmt.Errorf("mktemp: %w", err)
	}
	defer os.RemoveAll(workDir)

	// statsd uses relative `require("./backends/console")` so we
	// need the whole tree, not just stats.js. Copy from the nix
	// store path into a writable workdir.
	statsdDir := filepath.Join(workDir, "statsd")
	if err := copyDir(statsdSrc, statsdDir); err != nil {
		return fmt.Errorf("copy statsd src: %w", err)
	}

	configPath := filepath.Join(workDir, "config.js")
	configBody := fmt.Sprintf(`{
  port: %d,
  flushInterval: %d,
  backends: ["./backends/console"]
}
`, statsdPort, flushInterval)
	if err := os.WriteFile(configPath, []byte(configBody), 0644); err != nil {
		return fmt.Errorf("write config: %w", err)
	}

	// Pre-flight: prove the loopback UDP path itself works before
	// starting statsd. If THIS fails, the issue is environmental
	// (firewall, DNS, IPv6 weirdness). If this passes and statsd
	// doesn't see packets, the issue is Bun-side.
	if err := loopbackPreflight(); err != nil {
		return fmt.Errorf("loopback preflight failed: %w", err)
	}
	log.Print("loopback preflight OK")

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	cmd := exec.CommandContext(ctx, bunPath, filepath.Join(statsdDir, "stats.js"), configPath)
	cmd.Dir = statsdDir

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("stdout pipe: %w", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("stderr pipe: %w", err)
	}

	// Tee both streams: scan for needles AND echo to our stdout
	// so the user can see what statsd printed if anything fails.
	startupCh := make(chan struct{}, 1)
	flushCh := make(chan struct{}, 1)
	output := newSink()

	var wg sync.WaitGroup
	wg.Add(2)
	go scan("stdout", stdout, output, startupCh, flushCh, &wg)
	go scan("stderr", stderr, output, startupCh, flushCh, &wg)

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start bun: %w", err)
	}
	defer func() {
		// Even if Wait already returned, killing a finished
		// process is harmless.
		_ = cmd.Process.Kill()
		wg.Wait()
	}()

	// Wait for startup.
	select {
	case <-startupCh:
		log.Printf("statsd is up after %v", time.Since(startTime))
	case <-time.After(startupTimeout):
		return fmt.Errorf("startup timeout (%v) — statsd never printed %q\n--- captured output ---\n%s", startupTimeout, startupNeedle, output.String())
	}

	// Spam packets for the entire wait window — defeats any
	// startup race or one-off loss. Sender is the same 4-tuple
	// as the loopback preflight, which we know works.
	addr := fmt.Sprintf("127.0.0.1:%d", statsdPort)
	conn, err := net.Dial("udp", addr)
	if err != nil {
		return fmt.Errorf("dial udp: %w", err)
	}
	defer conn.Close()

	stopSpam := make(chan struct{})
	go func() {
		t := time.NewTicker(500 * time.Millisecond)
		defer t.Stop()
		for {
			select {
			case <-stopSpam:
				return
			case <-t.C:
				if _, err := conn.Write([]byte("foo:1|c\n")); err != nil {
					log.Printf("send error: %v", err)
				}
			}
		}
	}()
	defer close(stopSpam)
	log.Print("started spamming foo:1|c every 500ms")

	// Wait for the flush.
	select {
	case <-flushCh:
		log.Print("observed flush record containing 'foo'")
		return nil
	case <-time.After(flushTimeout):
		return fmt.Errorf("flush timeout (%v) — statsd never printed %q in a flush record\n--- captured output ---\n%s", flushTimeout, flushNeedle, output.String())
	}
}

var startTime = time.Now()

// scan reads lines from r, echoes them with a [tag] prefix, captures
// them into sink, and signals startupCh / flushCh when needles match.
func scan(tag string, r io.Reader, sink *sink, startupCh, flushCh chan<- struct{}, wg *sync.WaitGroup) {
	defer wg.Done()
	startupSignaled := false
	flushSignaled := false
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		fmt.Printf("[%s] %s\n", tag, line)
		sink.WriteLine(line)
		if !startupSignaled && strings.Contains(line, startupNeedle) {
			startupSignaled = true
			select {
			case startupCh <- struct{}{}:
			default:
			}
		}
		// Heuristic: any line that mentions our counter name AFTER
		// startup is a flush record. statsd's console backend prints
		// the full flush as one or more lines containing `foo`.
		if startupSignaled && !flushSignaled && strings.Contains(line, flushNeedle) {
			flushSignaled = true
			select {
			case flushCh <- struct{}{}:
			default:
			}
		}
	}
}

type sink struct {
	mu    sync.Mutex
	lines []string
}

func newSink() *sink { return &sink{} }

func (s *sink) WriteLine(line string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.lines = append(s.lines, line)
}

func (s *sink) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return strings.Join(s.lines, "\n")
}

// loopbackPreflight binds a Go UDP listener on the same port we'll
// give statsd, sends a packet, reads it back, closes. Proves the
// kernel + loopback + Go-stack path works before we test Bun.
func loopbackPreflight() error {
	addr := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: statsdPort}
	ln, err := net.ListenUDP("udp4", addr)
	if err != nil {
		return fmt.Errorf("listen: %w", err)
	}
	defer ln.Close()

	conn, err := net.DialUDP("udp4", nil, addr)
	if err != nil {
		return fmt.Errorf("dial: %w", err)
	}
	defer conn.Close()

	if _, err := conn.Write([]byte("preflight:1|c\n")); err != nil {
		return fmt.Errorf("write: %w", err)
	}

	buf := make([]byte, 64)
	if err := ln.SetReadDeadline(time.Now().Add(500 * time.Millisecond)); err != nil {
		return fmt.Errorf("set deadline: %w", err)
	}
	n, _, err := ln.ReadFromUDP(buf)
	if err != nil {
		return fmt.Errorf("read: %w", err)
	}
	got := strings.TrimSpace(string(buf[:n]))
	if got != "preflight:1|c" {
		return fmt.Errorf("unexpected payload: %q", got)
	}
	return nil
}

// copyDir does a plain recursive copy of src into dst. Files in the
// nix store are read-only; we relax permissions on copy so statsd's
// require() can chase symlinks and bun can read everything.
func copyDir(src, dst string) error {
	return filepath.Walk(src, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		if info.IsDir() {
			return os.MkdirAll(target, 0755)
		}
		// Symlinks: resolve relative ones into the dst tree, copy
		// absolute targets verbatim. statsd doesn't ship symlinks
		// itself but the store path may; safe to handle both.
		if info.Mode()&os.ModeSymlink != 0 {
			link, err := os.Readlink(path)
			if err != nil {
				return err
			}
			return os.Symlink(link, target)
		}
		in, err := os.Open(path)
		if err != nil {
			return err
		}
		defer in.Close()
		out, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
		if err != nil {
			return err
		}
		defer out.Close()
		_, err = io.Copy(out, in)
		return err
	})
}
