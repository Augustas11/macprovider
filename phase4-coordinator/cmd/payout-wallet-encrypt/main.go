// Command payout-wallet-encrypt produces the AES-256-GCM-encrypted hot
// wallet file the SPEC-016 payout signer loads (LoadLocalFileSigner).
//
// It is the vetted implementation of dist/payout-runbook.md §1.1–§1.2:
// it generates (or accepts) a secp256k1 private key, seals it under the
// operator's 32-byte KEK in the EXACT format the coordinator decrypts,
// and prints ONLY the resulting EIP-55 address. The plaintext private
// key is held in memory and never written to disk, removing the
// runbook's "openssl into /tmp then shred" hazard.
//
// RUN OFFLINE on a clean, network-isolated machine. Neither the private
// key nor the KEK is printed or logged.
//
// Usage:
//
//	# Generate a fresh hot wallet, encrypt under the KEK, write the file:
//	payout-wallet-encrypt -kek-file kek.hex -out payout-wallet.hex
//
//	# Or encrypt an existing raw 32-byte key (hex in a file):
//	payout-wallet-encrypt -kek-file kek.hex -key-file existing.hex -out payout-wallet.hex
//
// The KEK file must contain exactly 64 hex characters (32 bytes), e.g.
// produced by `openssl rand -hex 32`. Deploy `-out` to the coordinator
// host as payout.security.encrypted_wallet_path (OnDiskHex=true) and load
// the KEK via systemd LoadCredential=payout-wallet-kek.
package main

import (
	"bytes"
	"encoding/hex"
	"flag"
	"fmt"
	"os"
	"runtime"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/payout"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "payout-wallet-encrypt: "+err.Error())
		os.Exit(1)
	}
}

func run() error {
	kekFile := flag.String("kek-file", "", "path to a file containing the 32-byte KEK as 64 hex chars (required)")
	keyFile := flag.String("key-file", "", "optional path to an existing raw secp256k1 private key as 64 hex chars; if omitted a fresh key is generated")
	out := flag.String("out", "", "output path for the encrypted wallet file (required unless -verify; refuses to overwrite)")
	verify := flag.Bool("verify", false, "verify mode: decrypt an EXISTING wallet with the KEK and confirm it loads to -expect-address (run BEFORE funding)")
	walletFile := flag.String("wallet-file", "", "verify mode: path to the deployed encrypted wallet file")
	expectAddr := flag.String("expect-address", "", "verify mode: the EIP-55 address you are about to fund; must match the decrypted wallet")
	onDiskHex := flag.Bool("on-disk-hex", true, "verify mode: whether the wallet file is hex-encoded (this tool writes hex)")
	flag.Parse()

	if *verify {
		return runVerify(*kekFile, *walletFile, *expectAddr, *onDiskHex)
	}

	if *kekFile == "" || *out == "" {
		return fmt.Errorf("both -kek-file and -out are required")
	}
	if _, err := os.Stat(*out); err == nil {
		return fmt.Errorf("refusing to overwrite existing output file %q", *out)
	}

	kek, err := readHexFile(*kekFile, 32)
	if err != nil {
		return fmt.Errorf("read KEK: %w", err)
	}
	defer zero(kek)

	var keyBytes []byte
	if *keyFile != "" {
		keyBytes, err = readHexFile(*keyFile, 32)
		if err != nil {
			return fmt.Errorf("read key: %w", err)
		}
	} else {
		priv, gerr := payout.GenerateWalletKey()
		if gerr != nil {
			return gerr
		}
		keyBytes = priv.Serialize()
		priv.Zero() // wipe the private-key object once serialized
	}
	defer zero(keyBytes)

	addr, err := payout.WalletAddressForKey(keyBytes)
	if err != nil {
		return err
	}

	encHex, err := payout.EncryptWalletKey(keyBytes, kek)
	if err != nil {
		return err
	}

	// Write 0600 with O_EXCL so a concurrent/racing create also fails
	// closed rather than clobbering an existing wallet.
	f, err := os.OpenFile(*out, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return fmt.Errorf("create output: %w", err)
	}
	if _, err := f.WriteString(encHex); err != nil {
		f.Close()
		return fmt.Errorf("write output: %w", err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("close output: %w", err)
	}

	fmt.Printf("hot wallet address (EIP-55): %s\n", addr)
	fmt.Printf("encrypted wallet written:    %s (mode 0600, OnDiskHex=true)\n", *out)
	fmt.Println("next: set payout.security.hot_wallet_address to the address above,")
	fmt.Println("      deploy the encrypted file as payout.security.encrypted_wallet_path,")
	fmt.Println("      and load the KEK via systemd LoadCredential=payout-wallet-kek.")
	return nil
}

// runVerify decrypts an already-deployed encrypted wallet with the KEK and
// confirms the derived address matches -expect-address. Run this on the
// coordinator host against the EXACT deployed wallet file + KEK BEFORE any
// funding: it proves the full tuple (encrypted_wallet_path + KEK +
// on-disk-hex) loads to the intended address, so USDC is never sent to an
// address the coordinator cannot actually sign for.
func runVerify(kekFile, walletFile, expectAddr string, onDiskHex bool) error {
	if kekFile == "" || walletFile == "" || expectAddr == "" {
		return fmt.Errorf("-verify requires -kek-file, -wallet-file, and -expect-address")
	}
	kek, err := readHexFile(kekFile, 32)
	if err != nil {
		return fmt.Errorf("read KEK: %w", err)
	}
	defer zero(kek)

	signer, err := payout.LoadLocalFileSigner(payout.EncryptedWalletFile{Path: walletFile, OnDiskHex: onDiskHex}, kek)
	if err != nil {
		return fmt.Errorf("wallet did NOT load (bad KEK, wrong on-disk-hex, or corrupt file): %w", err)
	}
	got := signer.FromAddress()
	if !strings.EqualFold(strings.TrimSpace(expectAddr), got) {
		return fmt.Errorf("address MISMATCH: wallet decrypts to %s but -expect-address is %s — DO NOT FUND", got, expectAddr)
	}
	fmt.Printf("OK: wallet loads and controls %s — safe to fund this address.\n", got)
	return nil
}

// readHexFile reads a file expected to contain exactly wantBytes worth of
// hex (2*wantBytes hex chars, surrounding whitespace tolerated) and
// returns the decoded bytes.
func readHexFile(path string, wantBytes int) ([]byte, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	// Decode from []byte (no string(raw) copy that would linger in the
	// heap until GC), and wipe the raw file buffer once decoded. This is
	// best-effort GC-era cleanup, NOT secure-memory erasure — Go does not
	// guarantee the bytes are gone from all copies/pages.
	defer zero(raw)
	trimmed := bytes.TrimSpace(raw)
	b := make([]byte, hex.DecodedLen(len(trimmed)))
	n, err := hex.Decode(b, trimmed)
	if err != nil {
		zero(b)
		return nil, fmt.Errorf("not valid hex: %w", err)
	}
	b = b[:n]
	if len(b) != wantBytes {
		zero(b)
		return nil, fmt.Errorf("expected %d bytes (%d hex chars), got %d bytes", wantBytes, wantBytes*2, len(b))
	}
	return b, nil
}

// zero wipes b in place. Best-effort only: Go exposes no secure-memory
// primitive at this version, so a copy may survive in freed heap/pages
// until GC. runtime.KeepAlive keeps b reachable across the wipe so the
// compiler cannot elide the writes to a soon-dead slice.
func zero(b []byte) {
	for i := range b {
		b[i] = 0
	}
	runtime.KeepAlive(b)
}
