package tier2

import (
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/rs/zerolog"
)

type stagingPublisher struct{ staged *Catalog }

func (p *stagingPublisher) StageTier2(next *Catalog) { p.staged = next }

// SPEC-047-R001 v0.1.5: with a release publisher registered, a validated
// reload is STAGED and becomes the singleton only when the publisher promotes
// it — and only that exact catalog can be promoted.
func TestConfigureDefaultStrictStagesWhenAReleasePublisherIsRegistered(t *testing.T) {
	ResetForTest()
	t.Cleanup(ResetForTest)
	t.Cleanup(func() { SetReleasePublisher(nil) })
	before := Default()
	publisher := &stagingPublisher{}
	SetReleasePublisher(publisher)
	catalogRaw, publicKey := signedCatalogFixture(t, time.Now().UTC().Add(time.Hour), strings.Repeat("a", 64))
	cfg := config.Default().Tier2
	cfg.CatalogPath = writeTempCatalog(t, catalogRaw)
	cfg.CatalogPublicKey = publicKey
	next, err := ConfigureDefaultStrict(cfg, zerolog.Nop(), func(*Catalog) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	if publisher.staged != next {
		t.Fatal("validated catalog must be staged with the publisher")
	}
	if Default() != before {
		t.Fatal("staged catalog must not be published before the publisher promotes it")
	}
	if PublishStaged(NewCatalog()) {
		t.Fatal("only the staged catalog can be promoted")
	}
	if !PublishStaged(next) || Default() != next {
		t.Fatal("promotion installs the staged catalog")
	}
	if PublishStaged(next) {
		t.Fatal("a promoted catalog cannot be promoted twice")
	}
}
