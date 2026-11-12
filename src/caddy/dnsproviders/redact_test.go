package dnsproviders

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/libdns/duckdns"
	"github.com/libdns/libdns"
)

func TestRedact(t *testing.T) {
	err := redact(errors.New("GET https://x/?token=a%2Fb+c failed for a/b c"), "a/b c")
	if strings.Contains(err.Error(), "a/b") || strings.Contains(err.Error(), "a%2Fb") {
		t.Fatalf("secret left in %q", err)
	}
	if redact(nil, "x") != nil {
		t.Fatal("nil error changed")
	}
}

// libdns/duckdns puts a token of the wrong length in its error, before any network request.
func TestDuckDNSTokenNotInErrors(t *testing.T) {
	const token = "not-a-real-token-but-secret"
	p := &DuckDNS{&duckdns.Provider{APIToken: token}}
	recs := []libdns.Record{libdns.TXT{Name: "_acme-challenge", Text: "x"}}
	for name, call := range map[string]func() error{
		"append": func() error { _, err := p.AppendRecords(context.Background(), "halos.duckdns.org.", recs); return err },
		"set":    func() error { _, err := p.SetRecords(context.Background(), "halos.duckdns.org.", recs); return err },
		"delete": func() error { _, err := p.DeleteRecords(context.Background(), "halos.duckdns.org.", recs); return err },
	} {
		err := call()
		if err == nil {
			t.Fatalf("%s: a %d-character token was accepted", name, len(token))
		}
		if strings.Contains(err.Error(), token) {
			t.Fatalf("%s: token in error: %v", name, err)
		}
	}
}
