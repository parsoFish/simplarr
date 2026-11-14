package api

import (
	"bytes"
	"encoding/json"
	"io"
	"io/fs"
	"log/slog"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"sync"
	"testing"
	"time"

	"github.com/parsoFish/simplarr/app/internal/auth"
	"github.com/parsoFish/simplarr/app/internal/logging"
)

const (
	testPassword = "a perfectly good password"
	maxFailures  = 5
)

// syncBuffer is a bytes.Buffer that the server goroutines and the test can
// touch concurrently.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// env is a running server plus a cookie-keeping client.
type env struct {
	t      *testing.T
	srv    *httptest.Server
	client *http.Client
	svc    *auth.Service
	token  string
	logs   *syncBuffer
}

func newEnv(t *testing.T, static fs.FS) *env {
	t.Helper()
	logs := &syncBuffer{}
	logger := logging.New(logs, slog.LevelDebug)

	hasher := auth.NewHasher(auth.Params{Memory: 64, Time: 1, Threads: 1, SaltLen: 16, KeyLen: 32}, 2)
	svc, err := auth.NewService(auth.ServiceConfig{
		DataDir:  t.TempDir(),
		Hasher:   hasher,
		Sessions: auth.NewSessions(7*24*time.Hour, time.Now),
		Logger:   logger,
	})
	if err != nil {
		t.Fatalf("NewService: %v", err)
	}
	token, _ := svc.PendingSetupToken()

	srv := httptest.NewServer(NewHandler(Deps{
		Auth:    svc,
		Limiter: auth.NewLimiter(maxFailures, 15*time.Minute, time.Now),
		Static:  static,
		Logger:  logger,
	}))
	t.Cleanup(srv.Close)

	jar, err := cookiejar.New(nil)
	if err != nil {
		t.Fatal(err)
	}
	return &env{
		t: t, srv: srv, svc: svc, token: token, logs: logs,
		client: &http.Client{
			Jar:           jar,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
	}
}

// do sends a request. body, when non-nil, is sent as JSON. headers are
// key, value pairs.
func (e *env) do(method, path string, body any, headers ...string) (*http.Response, []byte) {
	e.t.Helper()
	var rdr io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			e.t.Fatal(err)
		}
		rdr = bytes.NewReader(raw)
	}
	req, err := http.NewRequest(method, e.srv.URL+path, rdr)
	if err != nil {
		e.t.Fatal(err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	for i := 0; i+1 < len(headers); i += 2 {
		req.Header.Set(headers[i], headers[i+1])
	}
	resp, err := e.client.Do(req)
	if err != nil {
		e.t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	out, err := io.ReadAll(resp.Body)
	if err != nil {
		e.t.Fatal(err)
	}
	return resp, out
}

func (e *env) cookie(name string) *http.Cookie {
	e.t.Helper()
	u, err := url.Parse(e.srv.URL)
	if err != nil {
		e.t.Fatal(err)
	}
	for _, c := range e.client.Jar.Cookies(u) {
		if c.Name == name {
			return c
		}
	}
	return nil
}

func (e *env) completeSetup() {
	e.t.Helper()
	resp, body := e.do("POST", "/api/v1/auth/setup", map[string]string{"token": e.token, "password": testPassword})
	if resp.StatusCode != http.StatusOK {
		e.t.Fatalf("setup: %d %s", resp.StatusCode, body)
	}
}

// login completes setup if needed, logs in, and returns the CSRF token.
func (e *env) login() string {
	e.t.Helper()
	if e.svc.SetupRequired() {
		e.completeSetup()
	}
	resp, body := e.do("POST", "/api/v1/auth/login", map[string]string{"password": testPassword})
	if resp.StatusCode != http.StatusOK {
		e.t.Fatalf("login: %d %s", resp.StatusCode, body)
	}
	c := e.cookie(csrfCookieName)
	if c == nil {
		e.t.Fatal("no csrf cookie after login")
	}
	return c.Value
}
