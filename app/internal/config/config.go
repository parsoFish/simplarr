// Package config reads simplarr's environment configuration (spec §4),
// validates it, and fails fast with messages that name the variable.
package config

import (
	"errors"
	"fmt"
	"net"
	"strconv"
	"strings"
)

// Topology is how the stack is deployed.
type Topology string

const (
	TopologyUnified Topology = "unified"
	TopologySplit   Topology = "split"
)

// Endpoint is how simplarr reaches one service.
type Endpoint struct {
	Host string
	Port int
}

// Address returns host:port, bracketing IPv6 literals.
func (e Endpoint) Address() string {
	return net.JoinHostPort(e.Host, strconv.Itoa(e.Port))
}

// Config is the validated, immutable process configuration.
type Config struct {
	Topology  Topology
	Listen    string
	ConfigDir string
	DataDir   string

	Radarr      Endpoint
	Sonarr      Endpoint
	Prowlarr    Endpoint
	Overseerr   Endpoint
	Tautulli    Endpoint
	QBittorrent Endpoint
	Plex        Endpoint

	NASIPDashed    string
	PlexDirectHash string
	SubdomainTLD   string
}

// PlexDirectHost returns the plex.direct host name when both NAS_IP_DASHED
// and PLEX_DIRECT_HASH are set. A partial pair is a normal state (the hash is
// only known after Plex is claimed), so it is not an error.
func (c Config) PlexDirectHost() (string, bool) {
	if c.NASIPDashed == "" || c.PlexDirectHash == "" {
		return "", false
	}
	return c.NASIPDashed + "." + c.PlexDirectHash + ".plex.direct", true
}

type serviceSpec struct {
	prefix      string
	defaultHost string
	defaultPort int
	onNAS       bool // in split mode the default host is NAS_IP
}

var (
	radarrSpec      = serviceSpec{"RADARR", "radarr", 7878, false}
	sonarrSpec      = serviceSpec{"SONARR", "sonarr", 8989, false}
	prowlarrSpec    = serviceSpec{"PROWLARR", "prowlarr", 9696, false}
	overseerrSpec   = serviceSpec{"OVERSEERR", "overseerr", 5055, false}
	tautulliSpec    = serviceSpec{"TAUTULLI", "tautulli", 8181, false}
	qbittorrentSpec = serviceSpec{"QBITTORRENT", "qbittorrent", 8080, true}
	plexSpec        = serviceSpec{"PLEX", "host.docker.internal", 32400, true}
)

// loader collects every problem so the operator can fix them in one pass.
type loader struct {
	getenv func(string) string
	errs   []error
}

// get returns the trimmed value; "" means unset. Trimming removes the stray
// \r that a CRLF .env file leaves behind.
func (l *loader) get(name string) string {
	return strings.TrimSpace(l.getenv(name))
}

func (l *loader) fail(name string, err error) {
	l.errs = append(l.errs, fmt.Errorf("%s: %w", name, err))
}

// checked returns the value of name (or def when unset) after validation.
func (l *loader) checked(name, def string, validate func(string) error) string {
	v := l.get(name)
	if v == "" {
		v = def
	}
	if err := validate(v); err != nil {
		l.fail(name, err)
	}
	return v
}

// optional returns the value when set and valid, "" when unset.
func (l *loader) optional(name string, validate func(string) error) string {
	v := l.get(name)
	if v == "" {
		return ""
	}
	if err := validate(v); err != nil {
		l.fail(name, err)
	}
	return v
}

func (l *loader) endpoint(s serviceSpec, nasIP string, topo Topology) Endpoint {
	def := s.defaultHost
	hostVar := s.prefix + "_HOST"
	if s.onNAS && topo == TopologySplit && l.get(hostVar) == "" {
		if nasIP == "" {
			l.fail("NAS_IP", fmt.Errorf("required when SIMPLARR_TOPOLOGY=split and %s is not set", hostVar))
		}
		def = nasIP
	}
	host := l.checked(hostVar, def, validateHost)

	port := s.defaultPort
	if v := l.get(s.prefix + "_PORT"); v != "" {
		p, err := parsePort(v)
		if err != nil {
			l.fail(s.prefix+"_PORT", err)
		} else {
			port = p
		}
	}
	return Endpoint{Host: host, Port: port}
}

// Load builds a Config from getenv (os.Getenv in production). It returns every
// validation problem joined into one error.
func Load(getenv func(string) string) (Config, error) {
	l := &loader{getenv: getenv}

	topo := Topology(l.get("SIMPLARR_TOPOLOGY"))
	switch topo {
	case "":
		topo = TopologyUnified
	case TopologyUnified, TopologySplit:
	default:
		l.fail("SIMPLARR_TOPOLOGY", fmt.Errorf("must be unified or split, got %q", string(topo)))
		topo = TopologyUnified
	}

	nasIP := l.optional("NAS_IP", validateHost)

	cfg := Config{
		Topology:  topo,
		Listen:    l.checked("SIMPLARR_LISTEN", ":8080", validateListen),
		ConfigDir: l.checked("SIMPLARR_CONFIG_DIR", "/config", validateDir),
		DataDir:   l.checked("SIMPLARR_DATA_DIR", "/data", validateDir),

		Radarr:      l.endpoint(radarrSpec, nasIP, topo),
		Sonarr:      l.endpoint(sonarrSpec, nasIP, topo),
		Prowlarr:    l.endpoint(prowlarrSpec, nasIP, topo),
		Overseerr:   l.endpoint(overseerrSpec, nasIP, topo),
		Tautulli:    l.endpoint(tautulliSpec, nasIP, topo),
		QBittorrent: l.endpoint(qbittorrentSpec, nasIP, topo),
		Plex:        l.endpoint(plexSpec, nasIP, topo),

		NASIPDashed:    l.optional("NAS_IP_DASHED", validateDashed),
		PlexDirectHash: l.optional("PLEX_DIRECT_HASH", validateDashed),
	}

	tld := strings.TrimPrefix(l.get("SUBDOMAIN_TLD"), ".")
	if tld == "" {
		tld = "local"
	}
	if err := validateTLD(tld); err != nil {
		l.fail("SUBDOMAIN_TLD", err)
	}
	cfg.SubdomainTLD = tld

	if len(l.errs) > 0 {
		return Config{}, errors.Join(l.errs...)
	}
	return cfg, nil
}
