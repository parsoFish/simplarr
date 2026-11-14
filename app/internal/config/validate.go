package config

import (
	"fmt"
	"net"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

var (
	tldPattern   = regexp.MustCompile(`^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$`)
	dashedHostRe = regexp.MustCompile(`^[A-Za-z0-9-]+$`)
)

// parsePort accepts only plain decimal digits in 1-65535 (no sign, no spaces).
func parsePort(s string) (int, error) {
	p, err := strconv.ParseUint(s, 10, 16)
	if err != nil || p == 0 {
		return 0, fmt.Errorf("must be a number between 1 and 65535, got %q", s)
	}
	return int(p), nil
}

// validateHost accepts a bare host name or IP address: no scheme, no path,
// no port. IPv6 literals (two or more colons) are allowed.
func validateHost(h string) error {
	switch {
	case h == "":
		return fmt.Errorf("must not be empty")
	case strings.Contains(h, "://"):
		return fmt.Errorf("must not include a scheme, got %q", h)
	case strings.ContainsAny(h, "/?#@ \t"):
		return fmt.Errorf("must be a bare host name or address, got %q", h)
	case strings.Count(h, ":") == 1:
		return fmt.Errorf("must not include a port (set the matching *_PORT variable), got %q", h)
	}
	return nil
}

// validateListen checks a host:port listen address. The host may be empty.
func validateListen(addr string) error {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return fmt.Errorf("must look like :8080 or 127.0.0.1:8080, got %q", addr)
	}
	if _, err := parsePort(port); err != nil {
		return err
	}
	if host != "" {
		if err := validateHost(host); err != nil {
			return err
		}
	}
	return nil
}

func validateDir(p string) error {
	if !filepath.IsAbs(p) {
		return fmt.Errorf("must be an absolute path, got %q", p)
	}
	return nil
}

func validateTLD(s string) error {
	if !tldPattern.MatchString(s) {
		return fmt.Errorf("must contain only letters, digits, dots and dashes, got %q", s)
	}
	return nil
}

// validateDashed checks the dashed-IP and hash pieces of a plex.direct name.
func validateDashed(s string) error {
	if !dashedHostRe.MatchString(s) {
		return fmt.Errorf("must contain only letters, digits and dashes, got %q", s)
	}
	return nil
}
