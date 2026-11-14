package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"testing"
)

const (
	setupPath  = "/api/v1/auth/setup"
	loginPath  = "/api/v1/auth/login"
	logoutPath = "/api/v1/auth/logout"
	statePath  = "/api/v1/auth/state"
)

type stateBody struct {
	SetupRequired bool `json:"setupRequired"`
	Authenticated bool `json:"authenticated"`
}

func getState(t *testing.T, e *env) stateBody {
	t.Helper()
	resp, body := e.do("GET", statePath, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("state: %d %s", resp.StatusCode, body)
	}
	var s stateBody
	if err := json.Unmarshal(body, &s); err != nil {
		t.Fatalf("state body: %v\n%s", err, body)
	}
	return s
}

func TestHealthz(t *testing.T) {
	e := newEnv(t, nil)
	resp, body := e.do("GET", "/healthz", nil)
	if resp.StatusCode != 200 || strings.TrimSpace(string(body)) != `{"ok":true}` {
		t.Errorf("healthz = %d %s", resp.StatusCode, body)
	}
}

func TestStateAcrossTheLifecycle(t *testing.T) {
	e := newEnv(t, nil)
	if s := getState(t, e); !s.SetupRequired || s.Authenticated {
		t.Errorf("fresh state = %+v", s)
	}
	e.completeSetup()
	if s := getState(t, e); s.SetupRequired || s.Authenticated {
		t.Errorf("after setup (not logged in) = %+v", s)
	}
	csrf := e.login()
	if s := getState(t, e); s.SetupRequired || !s.Authenticated {
		t.Errorf("after login = %+v", s)
	}
	e.do("POST", logoutPath, nil, "X-CSRF-Token", csrf)
	if s := getState(t, e); s.Authenticated {
		t.Errorf("after logout = %+v", s)
	}
}

// The web app writes the body of each setup, login and logout response straight
// into its cached auth state (web/src/api/auth.ts) and the route guards act on
// it, so every body must carry the state AFTER the call, as a whole.
func TestAuthEndpointsAnswerWithTheNewState(t *testing.T) {
	e := newEnv(t, nil)

	check := func(name string, resp *http.Response, body []byte, want stateBody) {
		t.Helper()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("%s: status = %d, want 200; body %s", name, resp.StatusCode, body)
		}
		if ct := resp.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
			t.Errorf("%s: Content-Type = %q, want application/json", name, ct)
		}
		var got stateBody
		if err := json.Unmarshal(body, &got); err != nil {
			t.Fatalf("%s: body is not a state object: %v\n%s", name, err, body)
		}
		if got != want {
			t.Errorf("%s: body = %+v, want %+v (raw %s)", name, got, want, body)
		}
		// A renamed or dropped key would decode as false and could pass for a
		// false-valued field, so require both keys to be present.
		var keys map[string]bool
		if err := json.Unmarshal(body, &keys); err != nil {
			t.Fatalf("%s: body is not a flat object of booleans: %v\n%s", name, err, body)
		}
		for _, k := range []string{"setupRequired", "authenticated"} {
			if _, ok := keys[k]; !ok {
				t.Errorf("%s: body has no %q key: %s", name, k, body)
			}
		}
	}

	resp, body := e.do("POST", setupPath, map[string]string{"token": e.token, "password": testPassword})
	check("setup", resp, body, stateBody{SetupRequired: false, Authenticated: false})

	resp, body = e.do("POST", loginPath, map[string]string{"password": testPassword})
	check("login", resp, body, stateBody{SetupRequired: false, Authenticated: true})

	csrf := e.cookie(csrfCookieName)
	if csrf == nil {
		t.Fatal("no csrf cookie after login")
	}
	resp, body = e.do("POST", logoutPath, nil, "X-CSRF-Token", csrf.Value)
	check("logout", resp, body, stateBody{SetupRequired: false, Authenticated: false})
}

func TestSetupErrors(t *testing.T) {
	e := newEnv(t, nil)

	resp, body := e.do("POST", setupPath, map[string]string{"token": "wrong-token", "password": testPassword})
	wantError(t, resp, body, 403, "invalid_setup_token")

	resp, body = e.do("POST", setupPath, map[string]string{"token": e.token, "password": "short"})
	wantError(t, resp, body, 400, "weak_password")

	if !getState(t, e).SetupRequired {
		t.Fatal("failed attempts completed setup")
	}

	e.completeSetup()
	resp, body = e.do("POST", setupPath, map[string]string{"token": e.token, "password": testPassword})
	wantError(t, resp, body, 409, "setup_complete")
}

func TestJSONBodyValidation(t *testing.T) {
	e := newEnv(t, nil)
	good := map[string]string{"token": e.token, "password": testPassword}

	resp, body := e.do("POST", setupPath, good, "Content-Type", "text/plain")
	wantError(t, resp, body, 415, "unsupported_media_type")

	// The content types a cross-site HTML form can send, and a missing one.
	for _, ct := range []string{"application/x-www-form-urlencoded", "multipart/form-data; boundary=x", ""} {
		resp, body = e.do("POST", setupPath, good, "Content-Type", ct)
		if resp.StatusCode != 415 {
			t.Errorf("Content-Type %q: status = %d, want 415; body %s", ct, resp.StatusCode, body)
			continue
		}
		wantError(t, resp, body, 415, "unsupported_media_type")
	}

	resp, body = e.do("POST", setupPath, map[string]any{"token": e.token, "password": testPassword, "extra": 1})
	wantError(t, resp, body, 400, "invalid_request")

	resp, body = e.do("POST", setupPath, map[string]string{"password": strings.Repeat("x", 70<<10)})
	wantError(t, resp, body, 413, "request_too_large")

	raw, err := http.Post(e.srv.URL+setupPath, "application/json", bytes.NewReader([]byte(`{"token":"a","password":"b"} {}`)))
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Body.Close()
	if raw.StatusCode != 400 {
		t.Errorf("trailing data: status = %d, want 400", raw.StatusCode)
	}

	if !getState(t, e).SetupRequired {
		t.Error("rejected requests completed setup")
	}
}

func TestLoginBeforeSetupAndWithWrongPassword(t *testing.T) {
	e := newEnv(t, nil)
	resp, body := e.do("POST", loginPath, map[string]string{"password": testPassword})
	wantError(t, resp, body, 409, "setup_required")

	e.completeSetup()
	resp, body = e.do("POST", loginPath, map[string]string{"password": "not the password"})
	wantError(t, resp, body, 401, "invalid_credentials")
}

func TestLogoutRequiresSessionAndCSRF(t *testing.T) {
	e := newEnv(t, nil)

	resp, body := e.do("POST", logoutPath, nil)
	wantError(t, resp, body, 401, "unauthorized")

	csrf := e.login()
	resp, body = e.do("POST", logoutPath, nil)
	wantError(t, resp, body, 403, "csrf_failed")
	resp, body = e.do("POST", logoutPath, nil, "X-CSRF-Token", "not-the-token")
	wantError(t, resp, body, 403, "csrf_failed")
	if !getState(t, e).Authenticated {
		t.Fatal("a rejected logout ended the session")
	}

	resp, body = e.do("POST", logoutPath, nil, "X-CSRF-Token", csrf)
	if resp.StatusCode != 200 {
		t.Fatalf("logout: %d %s", resp.StatusCode, body)
	}
	wantClearingCookies(t, resp, false)
}

func TestCSRFTokenIsBoundToTheSession(t *testing.T) {
	e := newEnv(t, nil)
	e.login()
	session := e.cookie(sessionCookieName).Value

	// An attacker who plants their own csrf cookie and sends the same value in
	// the header still fails: it does not equal the token stored in the session.
	req, err := http.NewRequest("POST", e.srv.URL+logoutPath, nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Cookie", sessionCookieName+"="+session+"; "+csrfCookieName+"=attacker-token")
	req.Header.Set("X-CSRF-Token", "attacker-token")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 403 {
		t.Errorf("status = %d, want 403", resp.StatusCode)
	}
}

func TestLogoutInvalidatesTheSessionServerSide(t *testing.T) {
	e := newEnv(t, nil)
	csrf := e.login()
	session := e.cookie(sessionCookieName).Value
	e.do("POST", logoutPath, nil, "X-CSRF-Token", csrf)

	req, err := http.NewRequest("POST", e.srv.URL+logoutPath, nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Cookie", sessionCookieName+"="+session+"; "+csrfCookieName+"="+csrf)
	req.Header.Set("X-CSRF-Token", csrf)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 401 {
		t.Errorf("replayed session: status = %d, want 401", resp.StatusCode)
	}
}

func TestSetupIsRateLimitedPerIP(t *testing.T) {
	e := newEnv(t, nil)
	for i := 0; i < maxFailures; i++ {
		resp, body := e.do("POST", setupPath, map[string]string{"token": "wrong", "password": testPassword})
		wantError(t, resp, body, 403, "invalid_setup_token")
	}
	// Blocked: even the correct token is refused.
	resp, body := e.do("POST", setupPath, map[string]string{"token": e.token, "password": testPassword})
	wantError(t, resp, body, 429, "rate_limited")
	if secs, err := strconv.Atoi(resp.Header.Get("Retry-After")); err != nil || secs <= 0 {
		t.Errorf("Retry-After = %q, want positive seconds", resp.Header.Get("Retry-After"))
	}
	// Another client address is unaffected.
	resp, body = e.do("POST", setupPath, map[string]string{"token": e.token, "password": testPassword}, "X-Real-IP", "203.0.113.9")
	if resp.StatusCode != 200 {
		t.Errorf("other IP: %d %s", resp.StatusCode, body)
	}
}

func TestLoginIsRateLimitedPerIP(t *testing.T) {
	e := newEnv(t, nil)
	e.completeSetup()
	for i := 0; i < maxFailures; i++ {
		resp, body := e.do("POST", loginPath, map[string]string{"password": "wrong password!"})
		wantError(t, resp, body, 401, "invalid_credentials")
	}
	resp, body := e.do("POST", loginPath, map[string]string{"password": testPassword})
	wantError(t, resp, body, 429, "rate_limited")

	resp, body = e.do("POST", loginPath, map[string]string{"password": testPassword}, "X-Real-IP", "203.0.113.9")
	if resp.StatusCode != 200 {
		t.Errorf("other IP: %d %s", resp.StatusCode, body)
	}
}

func TestSuccessfulLoginResetsTheFailureCount(t *testing.T) {
	e := newEnv(t, nil)
	e.completeSetup()
	wrong := map[string]string{"password": "wrong password!"}
	for i := 0; i < maxFailures-1; i++ {
		e.do("POST", loginPath, wrong)
	}
	if resp, body := e.do("POST", loginPath, map[string]string{"password": testPassword}); resp.StatusCode != 200 {
		t.Fatalf("login: %d %s", resp.StatusCode, body)
	}
	for i := 0; i < maxFailures; i++ {
		resp, body := e.do("POST", loginPath, wrong)
		wantError(t, resp, body, 401, "invalid_credentials")
	}
	resp, body := e.do("POST", loginPath, wrong)
	wantError(t, resp, body, 429, "rate_limited")
}

func TestLogsNeverContainSecrets(t *testing.T) {
	e := newEnv(t, nil)
	e.do("POST", setupPath, map[string]string{"token": "guessed-token-value", "password": "hunter2hunter2"})
	e.completeSetup()
	e.do("POST", loginPath, map[string]string{"password": "hunter3hunter3"})
	e.login()
	sessionID := e.cookie(sessionCookieName)
	csrfToken := e.cookie(csrfCookieName)
	if sessionID == nil || csrfToken == nil {
		t.Fatal("login did not leave the session and csrf cookies in the jar")
	}

	logs := e.logs.String()
	secrets := []string{"hunter2", "hunter3", "guessed-token-value", e.token, testPassword, sessionID.Value, csrfToken.Value}
	for _, secret := range secrets {
		if strings.Contains(logs, secret) {
			t.Errorf("logs contain %q:\n%s", secret, logs)
		}
	}
	for _, event := range []string{"setup token rejected", "admin password set", "login failed", "login succeeded"} {
		if !strings.Contains(logs, event) {
			t.Errorf("logs missing event %q:\n%s", event, logs)
		}
	}
}

// A burst of parallel guesses must not get more than maxFailures attempts: the
// limiter charges each attempt before the password is checked, so requests that
// are already in flight cannot all slip past a "not blocked yet" check.
func TestParallelLoginBurstCannotExceedTheLimit(t *testing.T) {
	e := newEnv(t, nil)
	e.completeSetup()

	const burst = 40
	codes := make(chan int, burst)
	var wg sync.WaitGroup
	for i := 0; i < burst; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			resp, _ := e.do("POST", loginPath, map[string]string{"password": "wrong password!"})
			codes <- resp.StatusCode
		}()
	}
	wg.Wait()
	close(codes)

	got := map[int]int{}
	for c := range codes {
		got[c]++
	}
	if got[401] != maxFailures || got[429] != burst-maxFailures {
		t.Errorf("status counts = %v, want %d x 401 and %d x 429", got, maxFailures, burst-maxFailures)
	}
}
