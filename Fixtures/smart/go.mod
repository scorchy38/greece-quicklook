module github.com/example/greece-sync

go 1.23

toolchain go1.23.2

require (
	github.com/fsnotify/fsnotify v1.8.0
	github.com/spf13/cobra v1.8.1
	golang.org/x/sync v0.9.0
	google.golang.org/grpc v1.68.0
)

require (
	github.com/inconshreveable/mousetrap v1.1.0 // indirect
	github.com/spf13/pflag v1.0.5 // indirect
	golang.org/x/net v0.31.0 // indirect
	golang.org/x/sys v0.27.0 // indirect
	google.golang.org/protobuf v1.35.2 // indirect
)

replace github.com/example/greece-proto => ../proto
