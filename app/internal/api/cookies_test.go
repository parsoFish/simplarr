package api

import (
	"net/http"
	"testing"
)

func TestLoginSetsHardenedCookies(t *testing.T) {
	e := newEnv(t, nil)
	e.completeSetup()
	resp, body := e.do("POST", loginPath, map[string]string{"password": testPassword})
	if resp.StatusCode != 200 {
		t.Fatalf("login: %d %s", resp.StatusCode, body)
	}

	cookies := map[string]*http.Cookie{}
	for _, c := range resp.Cookies() {
		cookies[c.Name] = c
	}
	sess, csrf := cookies[sessionCookieName], cookies[csrfCookieName]
	if sess == nil || csrf == nil {
		t.Fatalf("cookies = %v, want session and csrf", resp.Cookies())
	}
	for _, c := range []*http.Cookie{sess, csrf} {
		if c.Path != "/" || c.SameSite != http.SameSiteStrictMode || c.MaxAge != 7*24*3600 {
			t.Errorf("%s: path=%q samesite=%v maxage=%d", c.Name, c.Path, c.SameSite, c.MaxAge)
		}
		if c.Secure {
			t.Errorf("%s is Secure on a plain-HTTP request", c.Name)
		}
	}
	if !sess.HttpOnly {
		t.Error("session cookie must be HttpOnly")
	}
	if csrf.HttpOnly {
		t.Error("csrf cookie must be readable by the SPA (not HttpOnly)")
	}
	if len(sess.Value) < 43 || sess.Value == csrf.Value {
		t.Errorf("session id %q / csrf %q look wrong", sess.Value, csrf.Value)
	}
}

func TestCookiesAreSecureBehindHTTPSProxy(t *testing.T) {
	tests := []struct {
		proto      string
		wantSecure bool
	}{
		{"https", true},
		{"HTTPS", true}, // the header value is matched case-insensitively
		{"http", false},
	}
	e := newEnv(t, nil)
	e.completeSetup()
	for _, tc := range tests {
		t.Run(tc.proto, func(t *testing.T) {
			resp, body := e.do("POST", loginPath, map[string]string{"password": testPassword}, "X-Forwarded-Proto", tc.proto)
			if resp.StatusCode != 200 {
				t.Fatalf("login: %d %s", resp.StatusCode, body)
			}
			if len(resp.Cookies()) != 2 {
				t.Fatalf("cookies = %v", resp.Cookies())
			}
			for _, c := range resp.Cookies() {
				if c.Secure != tc.wantSecure {
					t.Errorf("%s: Secure = %v behind X-Forwarded-Proto: %s, want %v", c.Name, c.Secure, tc.proto, tc.wantSecure)
				}
			}
		})
	}
}

// wantClearingCookies asserts resp carries exactly the two cookies that end a
// session: both empty, expired, scoped to /, SameSite=Strict, the session one
// HttpOnly and the csrf one readable by the SPA. secure is whether the Secure
// flag is expected on both.
func wantClearingCookies(t *testing.T, resp *http.Response, secure bool) {
	t.Helper()
	got := resp.Cookies()
	if len(got) != 2 {
		t.Fatalf("logout set %d cookies, want 2 (session and csrf): %v", len(got), got)
	}
	byName := map[string]*http.Cookie{}
	for _, c := range got {
		byName[c.Name] = c
	}
	for name, httpOnly := range map[string]bool{sessionCookieName: true, csrfCookieName: false} {
		c := byName[name]
		if c == nil {
			t.Errorf("logout did not clear cookie %s: %v", name, got)
			continue
		}
		if c.Value != "" || c.MaxAge >= 0 {
			t.Errorf("cookie %s not cleared: value=%q maxage=%d", name, c.Value, c.MaxAge)
		}
		if c.Path != "/" || c.SameSite != http.SameSiteStrictMode {
			t.Errorf("cookie %s: path=%q samesite=%v, want / and Strict", name, c.Path, c.SameSite)
		}
		if c.HttpOnly != httpOnly {
			t.Errorf("cookie %s: HttpOnly = %v, want %v", name, c.HttpOnly, httpOnly)
		}
		if c.Secure != secure {
			t.Errorf("cookie %s: Secure = %v, want %v", name, c.Secure, secure)
		}
	}
}

func TestLogoutClearingCookiesAreSecureBehindHTTPSProxy(t *testing.T) {
	e := newEnv(t, nil)
	csrf := e.login()
	resp, body := e.do("POST", logoutPath, nil, "X-CSRF-Token", csrf, "X-Forwarded-Proto", "https")
	if resp.StatusCode != 200 {
		t.Fatalf("logout: %d %s", resp.StatusCode, body)
	}
	wantClearingCookies(t, resp, true)
}
