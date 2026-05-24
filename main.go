package main

import (
	"fmt"
	"unminermac/lib"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/2nthony/webview"
)

const (
	hostIP   = "127.0.0.1"
	hostPort = "47261" // Fixed http port because client-side uses `localstorage`
)

func main() {
	runApp()
}

func runApp() {
	// start: make the root dir is the `Resources`, global effected!
	ep, err := os.Executable()
	if err != nil {
		fmt.Println("os.Executable:", err)
	}
	err = os.Chdir(filepath.Join(filepath.Dir(ep), "..", "Resources"))
	if err != nil {
		fmt.Println("os.Chdir:", err)
	}
	// end

	w := webview.New(true)

	// Ensure xmrig is killed on shutdown. Order matters: KillMining must
	// run BEFORE webview destroy (LIFO defer order: last registered runs
	// first), so put it after w.Destroy.
	defer w.Destroy()
	defer lib.KillMining()

	// Handle Ctrl-C / SIGTERM from terminal launches and `osascript -e 'quit'`.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		fmt.Println("received signal, killing miner")
		lib.KillMining()
		os.Exit(0)
	}()

	lib.RegisterIPCEvents(w)

	w.SetTitle("UnminerMac")
	// 560x720 to comfortably hold the new card-based UI (640px max-width
	// app-shell with 20px side padding). Still fits any modern Mac display.
	w.SetSize(560, 720, webview.HintFixed)

	createServer()

	w.Navigate(fmt.Sprintf("http://%s:%s?%d", hostIP, hostPort, time.Now().UnixMilli()))

	w.Run()
}

func createServer() {
	lib.RegisterRoutes()

	go func() {
		fmt.Println(http.ListenAndServe(fmt.Sprintf("%s:%s", hostIP, hostPort), nil))
	}()
}
