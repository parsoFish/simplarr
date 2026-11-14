package auth

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

const goodPassword = "a perfectly good password"

func quietLogger() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

func newTestService(t *testing.T, dir string) (*Service, *fakeClock) {
	t.Helper()
	clock := newFakeClock()
	svc, err := NewService(ServiceConfig{
		DataDir:  dir,
		Hasher:   newTestHasher(),
		Sessions: NewSessions(testTTL, clock.Now),
		Logger:   quietLogger(),
	})
	if err != nil {
		t.Fatalf("NewService: %v", err)
	}
	return svc, clock
}

func completeSetup(t *testing.T, svc *Service) {
	t.Helper()
	tok, ok := svc.PendingSetupToken()
	if !ok {
		t.Fatal("no pending setup token")
	}
	mustNoErr(t, svc.Setup(context.Background(), tok, goodPassword))
}

func TestFreshServiceNeedsSetup(t *testing.T) {
	svc, _ := newTestService(t, t.TempDir())
	if !svc.SetupRequired() {
		t.Error("SetupRequired = false on an empty data dir")
	}
	tok, ok := svc.PendingSetupToken()
	if !ok || len(tok) != 32 {
		t.Errorf("PendingSetupToken = %q, %v; want 32 hex chars", tok, ok)
	}
	if _, err := svc.Login(context.Background(), goodPassword); !errors.Is(err, ErrSetupRequired) {
		t.Errorf("Login before setup: err = %v, want ErrSetupRequired", err)
	}
}

func TestSetupRejectsWrongTokenAndWeakPasswords(t *testing.T) {
	dir := t.TempDir()
	svc, _ := newTestService(t, dir)
	tok, _ := svc.PendingSetupToken()
	ctx := context.Background()

	for _, bad := range []string{"", "wrong", strings.ToUpper(tok), tok + "0"} {
		if err := svc.Setup(ctx, bad, goodPassword); !errors.Is(err, ErrInvalidSetupToken) {
			t.Errorf("token %q: err = %v, want ErrInvalidSetupToken", bad, err)
		}
	}
	for name, pw := range map[string]string{
		"empty":      "",
		"short":      "elevenchars",
		"too long":   strings.Repeat("x", maxPasswordBytes+1),
		"11 unicode": "ééééééééééé",
		"11 spaces":  "           ",
	} {
		if err := svc.Setup(ctx, tok, pw); !errors.Is(err, ErrWeakPassword) {
			t.Errorf("%s: err = %v, want ErrWeakPassword", name, err)
		}
	}
	if !svc.SetupRequired() {
		t.Error("failed attempts completed setup")
	}
	if _, err := os.Stat(filepath.Join(dir, "admin.json")); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("admin.json exists after failed setup: %v", err)
	}
}

func TestPasswordPolicyCountsCharactersNotBytes(t *testing.T) {
	if err := ValidatePassword("ééééééééééé"); err == nil { // 11 runes, 22 bytes
		t.Error("11 characters accepted")
	}
	if err := ValidatePassword("éééééééééééé"); err != nil { // 12 runes
		t.Errorf("12 characters rejected: %v", err)
	}
	if err := ValidatePassword(strings.Repeat("x", maxPasswordBytes)); err != nil {
		t.Errorf("max length rejected: %v", err)
	}
}

func TestSetupWritesAdminFileAndIsOneShot(t *testing.T) {
	dir := t.TempDir()
	svc, _ := newTestService(t, dir)
	tok, _ := svc.PendingSetupToken()
	mustNoErr(t, svc.Setup(context.Background(), tok, goodPassword))

	path := filepath.Join(dir, "admin.json")
	info, err := os.Stat(path)
	mustNoErr(t, err)
	if info.Mode().Perm() != 0o600 {
		t.Errorf("admin.json mode = %o, want 600", info.Mode().Perm())
	}
	raw, _ := os.ReadFile(path)
	if !strings.Contains(string(raw), `"version": 1`) {
		t.Errorf("admin.json has no version: %s", raw)
	}
	if !strings.Contains(string(raw), "$argon2id$") || strings.Contains(string(raw), goodPassword) {
		t.Errorf("admin.json must hold an argon2id hash and never the password: %s", raw)
	}

	if svc.SetupRequired() {
		t.Error("SetupRequired = true after setup")
	}
	if _, ok := svc.PendingSetupToken(); ok {
		t.Error("setup token still valid after setup")
	}
	if err := svc.Setup(context.Background(), tok, "another good password"); !errors.Is(err, ErrSetupComplete) {
		t.Errorf("second Setup: err = %v, want ErrSetupComplete", err)
	}
}

func TestConcurrentSetupHasExactlyOneWinner(t *testing.T) {
	svc, _ := newTestService(t, t.TempDir())
	tok, _ := svc.PendingSetupToken()

	var wg sync.WaitGroup
	results := make(chan error, 8)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			results <- svc.Setup(context.Background(), tok, goodPassword)
		}()
	}
	wg.Wait()
	close(results)

	wins, complete := 0, 0
	for err := range results {
		switch {
		case err == nil:
			wins++
		case errors.Is(err, ErrSetupComplete):
			complete++
		default:
			t.Errorf("unexpected error: %v", err)
		}
	}
	if wins != 1 || complete != 7 {
		t.Errorf("wins = %d, complete = %d; want 1 and 7", wins, complete)
	}
}

func TestLoginLogoutAndSessionLookup(t *testing.T) {
	svc, _ := newTestService(t, t.TempDir())
	completeSetup(t, svc)
	ctx := context.Background()

	if _, err := svc.Login(ctx, "the wrong password"); !errors.Is(err, ErrInvalidCredentials) {
		t.Errorf("wrong password: err = %v, want ErrInvalidCredentials", err)
	}
	sess, err := svc.Login(ctx, goodPassword)
	mustNoErr(t, err)
	got, ok := svc.Session(sess.ID)
	if !ok || got != sess {
		t.Errorf("Session = %+v, %v; want %+v, true", got, ok, sess)
	}
	svc.Logout(sess.ID)
	if _, ok := svc.Session(sess.ID); ok {
		t.Error("session survived Logout")
	}
	if svc.SessionTTL() != testTTL {
		t.Errorf("SessionTTL = %v", svc.SessionTTL())
	}
}

func TestAdminHashSurvivesRestart(t *testing.T) {
	dir := t.TempDir()
	first, _ := newTestService(t, dir)
	completeSetup(t, first)

	second, _ := newTestService(t, dir)
	if second.SetupRequired() {
		t.Fatal("SetupRequired = true after restart with admin.json present")
	}
	if _, ok := second.PendingSetupToken(); ok {
		t.Error("a setup token was issued although an admin exists")
	}
	if _, err := second.Login(context.Background(), goodPassword); err != nil {
		t.Errorf("Login after restart: %v", err)
	}
}

func TestCorruptAdminFileFailsFastAndNamesTheFile(t *testing.T) {
	good, err := newTestHasher().Hash(context.Background(), goodPassword)
	mustNoErr(t, err)
	cases := map[string]string{
		"not json":     "{{{",
		"empty object": "{}",
		"wrong ver":    `{"version":2,"passwordHash":"` + good + `"}`,
		"empty hash":   `{"version":1,"passwordHash":""}`,
		"bad hash":     `{"version":1,"passwordHash":"plaintext"}`,
		"unknown key":  `{"version":1,"passwordHash":"` + good + `","extra":true}`,
	}
	for name, content := range cases {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "admin.json")
			mustNoErr(t, os.WriteFile(path, []byte(content), 0o600))
			_, err := NewService(ServiceConfig{
				DataDir: dir, Hasher: newTestHasher(),
				Sessions: NewSessions(testTTL, newFakeClock().Now), Logger: quietLogger(),
			})
			if err == nil || !strings.Contains(err.Error(), path) {
				t.Errorf("err = %v, want error naming %s", err, path)
			}
		})
	}
}

func TestWideAdminFileIsTightenedAtStartup(t *testing.T) {
	dir := t.TempDir()
	first, _ := newTestService(t, dir)
	completeSetup(t, first)
	path := filepath.Join(dir, "admin.json")
	mustNoErr(t, os.Chmod(path, 0o644))

	newTestService(t, dir)
	info, err := os.Stat(path)
	mustNoErr(t, err)
	if info.Mode().Perm() != 0o600 {
		t.Errorf("mode = %o, want 600", info.Mode().Perm())
	}
}

func TestNewServiceUnreadableAdminFile(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root can read anything")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "admin.json")
	mustNoErr(t, os.WriteFile(path, []byte("{}"), 0o000))
	_, err := NewService(ServiceConfig{
		DataDir: dir, Hasher: newTestHasher(),
		Sessions: NewSessions(testTTL, newFakeClock().Now), Logger: quietLogger(),
	})
	if err == nil || !strings.Contains(err.Error(), path) {
		t.Errorf("err = %v, want error naming %s", err, path)
	}
}
