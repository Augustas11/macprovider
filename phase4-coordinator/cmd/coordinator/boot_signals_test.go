package main

import (
	"bufio"
	"bytes"
	"errors"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/rs/zerolog"
)

// The helper process plays a booting coordinator: optionally installs the
// boot SIGHUP guard, says "booting", then keeps "booting" for a while.
func TestBootSIGHUPGuardHelperProcess(t *testing.T) {
	if os.Getenv("MACPROVIDER_BOOT_GUARD_HELPER") == "" {
		t.Skip("helper process only")
	}
	if os.Getenv("MACPROVIDER_BOOT_GUARD_HELPER") == "guard" {
		installBootSIGHUPGuard(zerolog.New(os.Stdout))
	}
	os.Stdout.WriteString("booting\n")
	time.Sleep(1500 * time.Millisecond)
	os.Exit(0)
}

func runBootingHelper(t *testing.T, mode string) (*exec.Cmd, *bytes.Buffer) {
	t.Helper()
	cmd := exec.Command(os.Args[0], "-test.run=^TestBootSIGHUPGuardHelperProcess$")
	cmd.Env = append(os.Environ(), "MACPROVIDER_BOOT_GUARD_HELPER="+mode)
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	var rest bytes.Buffer
	r := bufio.NewReader(out)
	line, err := r.ReadString('\n')
	if err != nil || strings.TrimSpace(line) != "booting" {
		t.Fatalf("helper did not report booting: %q %v", line, err)
	}
	if err := cmd.Process.Signal(syscall.SIGHUP); err != nil {
		t.Fatal(err)
	}
	_, _ = rest.ReadFrom(r)
	return cmd, &rest
}

// The real condition: a SIGHUP during boot kills an unguarded Go process
// (systemd then sees a "clean" SIGHUP exit and does not restart it).
func TestSIGHUPDuringBootKillsAnUnguardedProcess(t *testing.T) {
	cmd, _ := runBootingHelper(t, "none")
	err := cmd.Wait()
	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) {
		t.Fatalf("unguarded helper survived SIGHUP: %v", err)
	}
	ws, ok := exitErr.Sys().(syscall.WaitStatus)
	if !ok || !ws.Signaled() || ws.Signal() != syscall.SIGHUP {
		t.Fatalf("unguarded helper did not die of SIGHUP: %v", err)
	}
}

func TestBootSIGHUPGuardIgnoresSIGHUPWhileBooting(t *testing.T) {
	cmd, out := runBootingHelper(t, "guard")
	if err := cmd.Wait(); err != nil {
		t.Fatalf("guarded coordinator must survive a SIGHUP while booting: %v (output %s)", err, out)
	}
	if !strings.Contains(out.String(), "coordinator_sighup_before_ready") {
		t.Fatalf("the ignored SIGHUP must be logged: %s", out)
	}
}

func TestBootSIGHUPGuardHandsOffToTheMainLoop(t *testing.T) {
	var logs bytes.Buffer
	g := installBootSIGHUPGuard(zerolog.New(&logs))
	mainCh := make(chan os.Signal, 1)
	signal.Notify(mainCh, syscall.SIGHUP)
	defer signal.Stop(mainCh)
	g.handOff()
	if err := syscall.Kill(os.Getpid(), syscall.SIGHUP); err != nil {
		t.Fatal(err)
	}
	select {
	case <-mainCh:
	case <-time.After(5 * time.Second):
		t.Fatal("after handOff the main loop must receive SIGHUP")
	}
	if strings.Contains(logs.String(), "coordinator_sighup_before_ready") {
		t.Fatalf("a SIGHUP after handOff is the main loop's, not ignored: %s", logs.String())
	}
}

// main() must install the guard before loading config and register the main
// SIGHUP handler (then hand off) before any listener starts.
func TestMainOrdersSIGHUPHandlingBeforeBootWorkAndListeners(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(src)
	guard := strings.Index(s, "installBootSIGHUPGuard(")
	load := strings.Index(s, "config.LoadWithOverlayDigests(*configPath, *configOverlay)")
	notify := strings.Index(s, "signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)")
	handOff := strings.Index(s, "bootSIGHUP.handOff()")
	listen := strings.Index(s, "providerHTTP.ListenAndServe()")
	record := strings.Index(s, `recordAppliedConfig(logger, "boot"`)
	for name, idx := range map[string]int{"guard": guard, "load": load, "notify": notify, "handOff": handOff, "listen": listen, "record": record} {
		if idx < 0 {
			t.Fatalf("main.go lacks %s", name)
		}
	}
	if !(guard < load && notify < handOff && handOff < listen && listen < record) {
		t.Fatalf("SIGHUP ordering broken: guard=%d load=%d notify=%d handOff=%d listen=%d record=%d", guard, load, notify, handOff, listen, record)
	}
}

func writeUnit(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestPricingRecoveryWiringCheck(t *testing.T) {
	dir := t.TempDir()
	root := filepath.Join(dir, "opt")
	unit := filepath.Join(dir, "etc/macprovider-coordinator-deploy-recovery.service")
	dropIn := filepath.Join(dir, "etc/10-deploy-transaction-guard.conf")
	oldUnit, oldDropIn := pricingRecoveryUnitPath, pricingGuardDropInPath
	pricingRecoveryUnitPath, pricingGuardDropInPath = unit, dropIn
	defer func() { pricingRecoveryUnitPath, pricingGuardDropInPath = oldUnit, oldDropIn }()
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	// The committed #1693 units carry the pricing wiring.
	repoUnits := filepath.Join("..", "..", "dist", "systemd")
	good, err := os.ReadFile(filepath.Join(repoUnits, "macprovider-coordinator-deploy-recovery.service"))
	if err != nil {
		t.Fatal(err)
	}
	goodDropIn, err := os.ReadFile(filepath.Join(repoUnits, "macprovider-coordinator-deploy-guard.conf"))
	if err != nil {
		t.Fatal(err)
	}
	// A pre-#1693 deploy reinstalls these bytes (its only pre-start is deploy-recover).
	oldRecovery := "[Unit]\nDescription=Recover interrupted Mac Provider coordinator deploy\nBefore=macprovider-coordinator.service\n\n[Service]\nType=oneshot\nExecStart=/opt/macprovider/coordinator-deploy-recover --pre-start\n"
	oldGuard := "[Unit]\nRequires=macprovider-coordinator-deploy-recovery.service\nAfter=macprovider-coordinator-deploy-recovery.service\n"

	writeUnit(t, unit, oldRecovery)
	writeUnit(t, dropIn, oldGuard)
	if p := pricingRecoveryWiringProblems(root); p != nil {
		t.Fatalf("no floor marker: nothing to report, got %v", p)
	}
	if err := os.WriteFile(filepath.Join(root, ".pricing-runtime-floor"), []byte("c\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	p := pricingRecoveryWiringProblems(root)
	if len(p) != 2 || !strings.Contains(p[0], "pre-start") || !strings.Contains(p[1], "closer") {
		t.Fatalf("floor + pre-#1693 units must report both missing pieces, got %v", p)
	}
	var logs bytes.Buffer
	checkPricingRecoveryWiring(zerolog.New(&logs), root)
	if !strings.Contains(logs.String(), `"event":"pricing_recovery_wiring_missing"`) || !strings.Contains(logs.String(), `"level":"error"`) {
		t.Fatalf("missing wiring must be logged loudly: %s", logs.String())
	}
	writeUnit(t, unit, string(good))
	writeUnit(t, dropIn, string(goodDropIn))
	if p := pricingRecoveryWiringProblems(root); p != nil {
		t.Fatalf("the committed #1693 units must satisfy the check, got %v", p)
	}
	if err := os.Remove(unit); err != nil {
		t.Fatal(err)
	}
	if p := pricingRecoveryWiringProblems(root); len(p) != 1 || !strings.Contains(p[0], "unreadable") {
		t.Fatalf("an unreadable recovery unit cannot prove the wiring, got %v", p)
	}
}
