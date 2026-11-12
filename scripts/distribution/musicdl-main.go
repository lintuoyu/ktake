package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"regexp"
	"strconv"
	"syscall"

	"github.com/guohuiyuan/go-music-dl/internal/web"
)

func main() {
	if len(os.Args) != 3 || !regexp.MustCompile(`^/ktake-[0-9a-f-]{36}/music$`).MatchString(os.Args[1]) {
		fmt.Fprintln(os.Stderr, "This helper is started by KTake.")
		os.Exit(2)
	}
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer cancel()
	go func() {
		// The only writer is KTake. Closing it also shuts us down after a force quit.
		_, _ = io.Copy(io.Discard, os.Stdin)
		cancel()
	}()
	web.StartWithOptions("0", web.StartOptions{
		BasePath:    os.Args[1],
		ListenHost:  "127.0.0.1",
		DisableAuth: true,
		Embedded:    ctx,
		Ready: func(addr net.Addr) error {
			port := strconv.Itoa(addr.(*net.TCPAddr).Port)
			return os.WriteFile(os.Args[2], []byte(port+"\n"), 0600)
		},
	})
}
