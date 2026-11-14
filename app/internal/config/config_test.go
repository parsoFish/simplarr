package config

import (
	"strings"
	"testing"
)

// env builds a getenv func from a map. Unset names return "".
func env(m map[string]string) func(string) string {
	return func(name string) string { return m[name] }
}

func TestLoadDefaultsUnified(t *testing.T) {
	cfg, err := Load(env(nil))
	if err != nil {
		t.Fatalf("Load with empty env: %v", err)
	}
	if cfg.Topology != TopologyUnified {
		t.Errorf("Topology = %q, want unified", cfg.Topology)
	}
	if cfg.Listen != ":8080" {
		t.Errorf("Listen = %q, want :8080", cfg.Listen)
	}
	if cfg.ConfigDir != "/config" || cfg.DataDir != "/data" {
		t.Errorf("dirs = %q, %q; want /config, /data", cfg.ConfigDir, cfg.DataDir)
	}
	want := map[string]Endpoint{
		"radarr":      {"radarr", 7878},
		"sonarr":      {"sonarr", 8989},
		"prowlarr":    {"prowlarr", 9696},
		"overseerr":   {"overseerr", 5055},
		"tautulli":    {"tautulli", 8181},
		"qbittorrent": {"qbittorrent", 8080},
		"plex":        {"host.docker.internal", 32400},
	}
	got := map[string]Endpoint{
		"radarr": cfg.Radarr, "sonarr": cfg.Sonarr, "prowlarr": cfg.Prowlarr,
		"overseerr": cfg.Overseerr, "tautulli": cfg.Tautulli,
		"qbittorrent": cfg.QBittorrent, "plex": cfg.Plex,
	}
	for name, w := range want {
		if got[name] != w {
			t.Errorf("%s = %+v, want %+v", name, got[name], w)
		}
	}
	if cfg.SubdomainTLD != "local" {
		t.Errorf("SubdomainTLD = %q, want local", cfg.SubdomainTLD)
	}
}

func TestLoadTrimsCarriageReturnsAndSpaces(t *testing.T) {
	cfg, err := Load(env(map[string]string{
		"RADARR_HOST":       "radarr-box\r",
		"RADARR_PORT":       "7878\r",
		"SIMPLARR_TOPOLOGY": "split\r",
		"NAS_IP":            " 10.0.0.2\r",
		"SUBDOMAIN_TLD":     ".home\r",
	}))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Radarr != (Endpoint{"radarr-box", 7878}) {
		t.Errorf("Radarr = %+v", cfg.Radarr)
	}
	if cfg.Topology != TopologySplit {
		t.Errorf("Topology = %q", cfg.Topology)
	}
	if cfg.QBittorrent.Host != "10.0.0.2" || cfg.Plex.Host != "10.0.0.2" {
		t.Errorf("split hosts = %q, %q; want 10.0.0.2", cfg.QBittorrent.Host, cfg.Plex.Host)
	}
	if cfg.SubdomainTLD != "home" {
		t.Errorf("SubdomainTLD = %q, want home (leading dot stripped)", cfg.SubdomainTLD)
	}
}

func TestLoadSplitNeedsNASIP(t *testing.T) {
	_, err := Load(env(map[string]string{"SIMPLARR_TOPOLOGY": "split"}))
	if err == nil || !strings.Contains(err.Error(), "NAS_IP") {
		t.Fatalf("err = %v, want error naming NAS_IP", err)
	}
}

func TestLoadSplitExplicitHostsDoNotNeedNASIP(t *testing.T) {
	cfg, err := Load(env(map[string]string{
		"SIMPLARR_TOPOLOGY": "split",
		"QBITTORRENT_HOST":  "nas.lan",
		"QBITTORRENT_PORT":  "8282",
		"PLEX_HOST":         "nas.lan",
	}))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.QBittorrent != (Endpoint{"nas.lan", 8282}) {
		t.Errorf("QBittorrent = %+v", cfg.QBittorrent)
	}
}

func TestLoadRejectsBadValuesNamingTheVariable(t *testing.T) {
	tests := []struct {
		name string
		env  map[string]string
		want string
	}{
		{"port zero", map[string]string{"RADARR_PORT": "0"}, "RADARR_PORT"},
		{"port too big", map[string]string{"SONARR_PORT": "65536"}, "SONARR_PORT"},
		{"port text", map[string]string{"PROWLARR_PORT": "abc"}, "PROWLARR_PORT"},
		{"port negative", map[string]string{"OVERSEERR_PORT": "-1"}, "OVERSEERR_PORT"},
		{"port signed", map[string]string{"TAUTULLI_PORT": "+80"}, "TAUTULLI_PORT"},
		{"host scheme", map[string]string{"RADARR_HOST": "http://radarr"}, "RADARR_HOST"},
		{"host path", map[string]string{"SONARR_HOST": "sonarr/api"}, "SONARR_HOST"},
		{"host with port", map[string]string{"PROWLARR_HOST": "prowlarr:9696"}, "PROWLARR_HOST"},
		{"host space", map[string]string{"OVERSEERR_HOST": "over seerr"}, "OVERSEERR_HOST"},
		{"topology", map[string]string{"SIMPLARR_TOPOLOGY": "cluster"}, "SIMPLARR_TOPOLOGY"},
		{"listen no port", map[string]string{"SIMPLARR_LISTEN": "localhost"}, "SIMPLARR_LISTEN"},
		{"listen bad port", map[string]string{"SIMPLARR_LISTEN": ":99999"}, "SIMPLARR_LISTEN"},
		{"config dir relative", map[string]string{"SIMPLARR_CONFIG_DIR": "config"}, "SIMPLARR_CONFIG_DIR"},
		{"data dir relative", map[string]string{"SIMPLARR_DATA_DIR": "./data"}, "SIMPLARR_DATA_DIR"},
		{"tld", map[string]string{"SUBDOMAIN_TLD": "bad tld"}, "SUBDOMAIN_TLD"},
		{"dashed", map[string]string{"NAS_IP_DASHED": "10.0.0.2"}, "NAS_IP_DASHED"},
		{"hash", map[string]string{"PLEX_DIRECT_HASH": "a/b"}, "PLEX_DIRECT_HASH"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, err := Load(env(tc.env))
			if err == nil {
				t.Fatal("Load succeeded, want error")
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Errorf("error %q does not name %s", err, tc.want)
			}
		})
	}
}

func TestLoadReportsEveryProblemAtOnce(t *testing.T) {
	_, err := Load(env(map[string]string{"RADARR_PORT": "0", "SONARR_HOST": "http://x"}))
	if err == nil {
		t.Fatal("want error")
	}
	for _, name := range []string{"RADARR_PORT", "SONARR_HOST"} {
		if !strings.Contains(err.Error(), name) {
			t.Errorf("error %q missing %s", err, name)
		}
	}
}

func TestLoadAcceptsIPv6AndListenHost(t *testing.T) {
	cfg, err := Load(env(map[string]string{
		"RADARR_HOST":     "fd00::5",
		"SIMPLARR_LISTEN": "127.0.0.1:9000",
	}))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Radarr.Host != "fd00::5" {
		t.Errorf("Radarr.Host = %q", cfg.Radarr.Host)
	}
	if got := cfg.Radarr.Address(); got != "[fd00::5]:7878" {
		t.Errorf("Address() = %q, want [fd00::5]:7878", got)
	}
}

func TestPlexDirectHost(t *testing.T) {
	both, err := Load(env(map[string]string{"NAS_IP_DASHED": "10-0-0-2", "PLEX_DIRECT_HASH": "abc123"}))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	host, ok := both.PlexDirectHost()
	if !ok || host != "10-0-0-2.abc123.plex.direct" {
		t.Errorf("PlexDirectHost() = %q, %v", host, ok)
	}

	for name, m := range map[string]map[string]string{
		"neither":   {},
		"only hash": {"PLEX_DIRECT_HASH": "abc123"},
		"only ip":   {"NAS_IP_DASHED": "10-0-0-2"},
	} {
		cfg, err := Load(env(m))
		if err != nil {
			t.Fatalf("%s: Load: %v", name, err)
		}
		if host, ok := cfg.PlexDirectHost(); ok {
			t.Errorf("%s: PlexDirectHost() = %q, true; want not ok", name, host)
		}
	}
}
