//go:build ignore

// Lab-only (#1690 e2e mixed pairing B): drop GGUF artifacts from a lab
// catalog-artifacts feed and re-sign it with the lab static-feed seed, so an
// origin/main coordinator (which strict-decodes the feed and predates the
// GGUF file_path tuple) can start. Never touches a production key.
package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

func main() {
	dir, keyFile := os.Args[1], os.Args[2]
	raw, err := os.ReadFile(dir + "/catalog-artifacts.json")
	must(err)
	var doc map[string]any
	must(json.Unmarshal(raw, &doc))
	dropped := 0
	for _, m := range doc["models"].(map[string]any) {
		arts := m.(map[string]any)["artifacts"].(map[string]any)
		for k, a := range arts {
			if a.(map[string]any)["runtime_format"] == "gguf" {
				delete(arts, k)
				dropped++
				continue
			}
			// origin/main allows only mlx_cache on an MLX primary.
			a.(map[string]any)["allowed_runtime_sources"] = []string{"mlx_cache"}
		}
	}
	body, err := json.Marshal(doc)
	must(err)
	seedRaw, err := os.ReadFile(keyFile)
	must(err)
	seed, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(seedRaw)))
	must(err)
	priv := ed25519.NewKeyFromSeed(seed)
	var sidecar map[string]string
	sraw, err := os.ReadFile(dir + "/catalog-artifacts.json.sig")
	must(err)
	must(json.Unmarshal(sraw, &sidecar))
	sidecar["signature"] = base64.StdEncoding.EncodeToString(ed25519.Sign(priv, body))
	sb, err := json.Marshal(sidecar)
	must(err)
	must(os.WriteFile(dir+"/catalog-artifacts.json", body, 0o644))
	must(os.WriteFile(dir+"/catalog-artifacts.json.sig", sb, 0o644))
	fmt.Printf("dropped %d gguf artifacts, re-signed as %s\n", dropped, sidecar["key_id"])
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}
