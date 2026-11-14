package api

import (
	"net"
	"net/http"
	"net/netip"
	"strings"
)

// clientIP returns the address used to rate-limit a request.
//
// simplarr publishes no port: the only thing that can reach it is nginx, which
// sets X-Real-IP from the TCP peer (spec §8.2). A direct connection (tests,
// `docker exec`) has no header and falls back to the peer address. The header
// is only trusted because of that network layout; if simplarr is ever exposed
// directly, a client could vary it to dodge the limiter.
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
