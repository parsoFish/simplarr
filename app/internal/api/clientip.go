package api

import (
	"net"
	"net/http"
	"net/netip"
	"strings"
)

// clientIP returns the address used to rate-limit a request.
//
// Deployment assumption (set up when the app joins compose and nginx in a later
// plan): the app publishes no port and only nginx can reach it; nginx sets
// X-Real-IP from the TCP peer (spec §8.2). Until then the header is trusted
// from any caller, so a client that can reach the app directly can choose its
// own address and dodge the limiter. A direct connection (tests, `docker exec`)
// has no header and falls back to the peer address.
func clientIP(r *http.Request) string {
	if v := strings.TrimSpace(r.Header.Get("X-Real-IP")); v != "" {
		if addr, err := netip.ParseAddr(v); err == nil {
			return addr.Unmap().String()
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
