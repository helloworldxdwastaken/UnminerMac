package lib

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/2nthony/webview"
	"github.com/pkg/browser"
)

// Default unMineable referral code used when the user hasn't supplied
// one. Buried Go-side on purpose: the UI field stays empty so the user
// can override (or clear) it, but the actual xmrig invocation always
// has a referral attached so the 0.75% fee discount applies.
const defaultReferralCode = "lzt8-k3mf"

// detectPCores returns the number of performance cores on Apple Silicon,
// or 0 if unknown (Intel Macs / non-Darwin / sysctl missing).
func detectPCores() int {
	out, err := exec.Command("sysctl", "-n", "hw.perflevel0.physicalcpu").Output()
	if err != nil {
		return 0
	}
	n, err := strconv.Atoi(strings.TrimSpace(string(out)))
	if err != nil {
		return 0
	}
	return n
}

// Package-level so KillMining() can reach it from main.go on shutdown.
var miningProcess *exec.Cmd

// KillProcessGroup stops a running command and any descendants by signalling
// the whole process group (set up in run_command.go via Setpgid). Falls back
// to SIGKILL after a short grace period.
func KillProcessGroup(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	pid := cmd.Process.Pid
	// Negative pid → whole process group.
	if err := syscall.Kill(-pid, syscall.SIGTERM); err != nil {
		// Fallback: kill just the leader if the group call failed.
		_ = cmd.Process.Kill()
	}
	// Give it up to ~500ms to exit cleanly, then SIGKILL the group.
	done := make(chan struct{})
	go func() { _, _ = cmd.Process.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(500 * time.Millisecond):
		_ = syscall.Kill(-pid, syscall.SIGKILL)
		_ = cmd.Process.Kill()
	}
}

// KillMining stops the running miner if any. Safe to call when no miner
// is running. Called from main.go on app shutdown + signal handlers.
func KillMining() {
	KillProcessGroup(miningProcess)
	miningProcess = nil
}

// Verus address validation: must start with R, i, or zs1.
// Does not validate checksums — pool will reject bad addresses.
func isValidVerusAddress(addr string) bool {
	if len(addr) < 34 {
		return false
	}
	return strings.HasPrefix(addr, "R") ||
		strings.HasPrefix(addr, "i") ||
		strings.HasPrefix(addr, "zs1")
}

// client events
func RegisterIPCEvents(w webview.WebView) {
	minerPath := Ternay(IsIntel(), "assets/miner/xmrig", "assets/miner/xmrig-m1")
	verusPath := "assets/miner/verusminer"

	w.Bind("emitPageReady", func() {
		fmt.Println("emitPageReady")
		w.Eval(fmt.Sprintf(`
        onPageReady({
          cpuCores: %d,
          pCores: %d
        })
        `,
			runtime.NumCPU(),
			detectPCores(),
		))
	})

	type Form struct {
		Algorithm    string `json:"algorithm"` // "randomx" | "verushash"
		Symbol       string `json:"symbol"`
		Address      string `json:"address"`
		ReferralCode string `json:"referralCode"`
		CPUUsage     int    `json:"cpuUsage"`
	}

	w.Bind("emitStartMining", func(data string) {
		var form Form
		json.Unmarshal([]byte(data), &form)

		fmt.Printf("form: %v\n", form)

		if miningProcess != nil {
			w.Eval("onMiningStarted()")
			return
		}

		algo := strings.ToLower(strings.TrimSpace(form.Algorithm))
		if algo == "" {
			algo = "randomx"
		}

		switch algo {
		case "randomx":
			refCode := strings.TrimSpace(form.ReferralCode)
			if refCode == "" {
				refCode = defaultReferralCode
			}
			process, err := RunCommand(
				fmt.Sprintf(`%s --no-color --url=rx.unmineable.com:3333 --algo=rx --pass=x --keepalive --user=%s:%s.UnminerMac#%s --cpu-max-threads-hint=%s`, minerPath, form.Symbol, form.Address, refCode, fmt.Sprint(form.CPUUsage)),
			)
			if err != nil {
				w.Eval(fmt.Sprintf(`onMiningStartedError("%s")`, err))
				return
			}
			w.Eval("onMiningStarted()")
			miningProcess = process

		case "verushash":
			addr := strings.TrimSpace(form.Address)
			if !isValidVerusAddress(addr) {
				w.Eval(`onMiningStartedError("Invalid Verus address. Must start with R, i, or zs1.")`)
				return
			}
			// Convert CPU slider % → thread count for verusminer.
			// CPUUsage is 0-100 (% of total cores). On M5 with 10 cores
			// the default 40 = 4 P-cores. Minimum 1 thread.
			totalCores := runtime.NumCPU()
			threads := (form.CPUUsage * totalCores) / 100
			if threads < 1 {
				threads = 1
			}
			if threads > totalCores {
				threads = totalCores
			}
			process, err := RunCommand(
				fmt.Sprintf(`%s mine %s %d`, verusPath, addr, threads),
			)
			if err != nil {
				w.Eval(fmt.Sprintf(`onMiningStartedError("%s")`, err))
				return
			}
			w.Eval("onMiningStarted()")
			miningProcess = process

		default:
			w.Eval(fmt.Sprintf(`onMiningStartedError("Unknown algorithm: %s")`, algo))
		}
	})

	w.Bind("emitStopMining", func() {
		if miningProcess != nil {
			KillMining()
			w.Eval("onMiningStopped()")
		}
	})

	w.Bind("emitOpenURL", func(url string) {
		browser.OpenURL(url)
	})
}
