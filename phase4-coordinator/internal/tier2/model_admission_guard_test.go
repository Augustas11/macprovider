package tier2

import (
	"runtime"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/rs/zerolog"
)

func admissionGuardCatalog(t *testing.T) (*Catalog, config.Tier2Config) {
	t.Helper()
	raw, key := signedCatalogFixture(t, time.Now().UTC().Add(time.Hour), testHash)
	cfg := config.Tier2Config{CatalogPath: writeTempCatalog(t, raw), CatalogPublicKey: key}
	c := NewCatalog()
	if err := c.ConfigureStrict(cfg, zerolog.Nop()); err != nil {
		t.Fatal(err)
	}
	setDefaultForTest(c)
	t.Cleanup(ResetForTest)
	return c, cfg
}

func TestModelAdmissionCatalogPinContentionAndCleanup(t *testing.T) {
	c, _ := admissionGuardCatalog(t)
	for name, lock := range map[string]*sync.RWMutex{"publication": &defaultPublicationMu, "state": &c.mu} {
		t.Run(name, func(t *testing.T) {
			lock.Lock()
			_, release, ok := TryPinSnapshotMaterial(c, "model-a", testHash)
			lock.Unlock()
			if ok || release != nil {
				t.Fatal("contended owner accepted")
			}
			if !defaultPublicationMu.TryLock() {
				t.Fatal("publication pin leaked")
			}
			defaultPublicationMu.Unlock()
			if !c.mu.TryLock() {
				t.Fatal("state pin leaked")
			}
			c.mu.Unlock()
		})
	}
	for name, expected := range map[string]*Catalog{"nil": nil, "old": NewCatalog()} {
		t.Run(name, func(t *testing.T) {
			if _, release, ok := TryPinSnapshotMaterial(expected, "model-a", testHash); ok || release != nil {
				t.Fatal("wrong catalog accepted")
			}
		})
	}
	if _, release, ok := TryPinSnapshotMaterial(c, "missing-model", testHash); ok || release != nil {
		t.Fatal("missing material accepted")
	}
	want, _ := c.RouteSnapshotMaterial("model-a", testHash)
	got, release, ok := TryPinSnapshotMaterial(c, "model-a", testHash)
	if !ok {
		t.Fatal("valid pin failed")
	}
	release()
	if got != want {
		t.Fatal("pin changed existing material contract")
	}
}

func TestModelAdmissionCatalogPinSerializesPublications(t *testing.T) {
	for _, name := range []string{"default_reload", "test_reset", "test_default", "configure", "configure_strict"} {
		t.Run(name, func(t *testing.T) {
			c, cfg := admissionGuardCatalog(t)
			before, release, ok := TryPinSnapshotMaterial(c, "model-a", testHash)
			if !ok {
				t.Fatal("initial pin failed")
			}
			done := make(chan error, 1)
			lock := &defaultPublicationMu
			if name == "configure" || name == "configure_strict" {
				lock = &c.mu
			}
			go func() {
				switch name {
				case "default_reload":
					_, err := ConfigureDefaultStrict(cfg, zerolog.Nop(), func(*Catalog) error { return nil })
					done <- err
				case "test_reset":
					ResetForTest()
					done <- nil
				case "test_default":
					setDefaultForTest(NewCatalog())
					done <- nil
				case "configure":
					done <- c.Configure(config.Tier2Config{}, zerolog.Nop())
				case "configure_strict":
					done <- c.ConfigureStrict(config.Tier2Config{}, zerolog.Nop())
				}
			}()
			deadline := time.Now().Add(5 * time.Second)
			for lock.TryRLock() {
				lock.RUnlock()
				if time.Now().After(deadline) {
					release()
					t.Fatal("publisher did not reach pin")
				}
				runtime.Gosched()
			}
			if _, unlock, ok := TryPinSnapshotMaterial(c, "model-a", testHash); ok || unlock != nil {
				release()
				t.Fatal("pending publisher did not reject guard promptly")
			}
			select {
			case <-done:
				release()
				t.Fatal("publication crossed pin")
			default:
			}
			release()
			select {
			case err := <-done:
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("publisher stayed blocked")
			}
			if _, unlock, ok := TryPinSnapshotMaterial(c, "model-a", testHash); ok || unlock != nil {
				if unlock != nil {
					unlock()
				}
				t.Fatal("completed replacement not observed")
			}
			if before.CatalogID == "" || before.ExpectedModelHash != testHash {
				t.Fatal("snapshot changed after publication")
			}
			if name == "default_reload" {
				if _, unlock, ok := TryPinSnapshotMaterial(Default(), "model-a", testHash); !ok {
					t.Fatal("replacement is not pinnable")
				} else {
					unlock()
				}
			}
		})
	}
}
