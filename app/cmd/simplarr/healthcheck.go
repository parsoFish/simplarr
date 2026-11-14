package main

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"time"

	"github.com/parsoFish/simplarr/app/internal/config"
)

const healthcheckTimeout = 3 * time.Second

// cmdHealthcheck is the container HEALTHCHECK: the distroless image has no
// curl, so the binary probes itself. It exits 0 only if /healthz answers 200.
func cmdHealthcheck(stderr io.Writer, getenv func(string) string) int {
	cfg, err := config.Load(getenv)
	if err != nil {
		fmt.Fprintf(stderr, "healthcheck: invalid configuration:\n%v\n", err)
		return 1
	}
	url, err := probeURL(cfg.Listen)
	if err != nil {
		fmt.Fprintf(stderr, "healthcheck: %v\n", err)
		return 1
	}
	if err := probe(&http.Client{Timeout: healthcheckTimeout}, url); err != nil {
		fmt.Fprintf(stderr, "healthcheck: %v\n", err)
		return 1
	}
	return 0
}

// probeURL turns the listen address into a loopback URL: a wildcard bind
// (":8080", "0.0.0.0:8080", "[::]:8080") is reached through 127.0.0.1.
func probeURL(listen string) (string, error) {
	host, port, err := net.SplitHostPort(listen)
	if err != nil {
		return "", fmt.Errorf("listen address %q: %w", listen, err)
	}
	if ip := net.ParseIP(host); host == "" || (ip != nil && ip.IsUnspecified()) {
		host = "127.0.0.1"
	}
	return "http://" + net.JoinHostPort(host, port) + "/healthz", nil
}

func probe(client *http.Client, url string) error {
	resp, err := client.Get(url)
	if err != nil {
		return fmt.Errorf("GET %s: %w", url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("GET %s: status %d", url, resp.StatusCode)
	}
	return nil
}
