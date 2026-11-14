// This file makes web/ a separate Go module with no packages. Without it,
// `go vet ./...` and `go test ./...` in app/ descend into web/node_modules and
// pick up .go files that some npm packages ship (for example flatted/golang).
module github.com/parsoFish/simplarr/app/web

go 1.25.0
