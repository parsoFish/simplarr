package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/parsoFish/simplarr/app/internal/api"
	"github.com/parsoFish/simplarr/app/internal/auth"
	"github.com/parsoFish/simplarr/app/internal/config"
	"github.com/parsoFish/simplarr/app/internal/logging"
	"github.com/parsoFish/simplarr/app/internal/store"
	"github.com/parsoFish/simplarr/app/internal/webui"
)

const (
	sessionTTL      = 7 * 24 * time.Hour // spec §8.2
	loginMaxFails   = 5                  // spec §8.2: 5 failures ...
	loginFailWindow = 15 * time.Minute   // ... per 15 minutes per IP
	hashConcurrency = 2                  // argon2id uses 64 MiB per hash
	shutdownTimeout = 10 * time.Second
)

// cmdServe loads configuration, prepares state, then serves until SIGINT or
// SIGTERM. Anything wrong with the configuration or the data directory stops
// the process before it binds a port.
func cmdServe(stdout, stderr io.Writer, getenv func(string) string) int {
	cfg, err := config.Load(getenv)
	if err != nil {
		fmt.Fprintf(stderr, "simplarr: invalid configuration:\n%v\n", err)
		return 1
	}
	logger := logging.New(stdout, slog.LevelInfo)

	handler, err := buildHandler(cfg, logger, webui.Dist())
	if err != nil {
		logger.Error("startup failed", "err", err)
		return 1
	}
	ln, err := net.Listen("tcp", cfg.Listen)
	if err != nil {
		logger.Error("cannot listen", "addr", cfg.Listen, "err", err)
		return 1
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	logger.Info("simplarr listening", "addr", ln.Addr().String(), "version", version, "topology", string(cfg.Topology))
	if err := serveHTTP(ctx, ln, handler, logger); err != nil {
		logger.Error("server stopped", "err", err)
		return 1
	}
	return 0
}

// buildHandler prepares /data, loads the admin state, prints the setup token
// when first-run setup is pending, and returns the HTTP handler.
func buildHandler(cfg config.Config, logger *slog.Logger, static fs.FS) (http.Handler, error) {
	// Package-level slog calls (for example in internal/api) must go through the
	// redacting handler too.
	slog.SetDefault(logger)

	if err := store.EnsureDir(cfg.DataDir); err != nil {
		return nil, err
	}
	svc, err := auth.NewService(auth.ServiceConfig{
		DataDir:  cfg.DataDir,
		Hasher:   auth.NewHasher(auth.DefaultParams, hashConcurrency),
		Sessions: auth.NewSessions(sessionTTL, time.Now),
		Logger:   logger,
	})
	if err != nil {
		return nil, err
	}
	if token, pending := svc.PendingSetupToken(); pending {
		auth.AnnounceSetupToken(logger, token)
	}
	return api.NewHandler(api.Deps{
		Auth:    svc,
		Limiter: auth.NewLimiter(loginMaxFails, loginFailWindow, time.Now),
		Logger:  logger,
		Static:  static,
	}), nil
}

// serveHTTP serves on ln until ctx ends, then drains in-flight requests.
func serveHTTP(ctx context.Context, ln net.Listener, handler http.Handler, logger *slog.Logger) error {
	srv := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       2 * time.Minute,
		ErrorLog:          slog.NewLogLogger(logger.Handler(), slog.LevelError),
	}
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ln) }()

	select {
	case err := <-errc:
		return err // Serve only returns a non-nil error
	case <-ctx.Done():
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("shutdown: %w", err)
	}
	if err := <-errc; !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}
