package dnsproviders

import (
	"errors"
	"net/url"
	"strings"
)

// redact replaces each secret, raw and URL-encoded, in an error's text with REDACTED. Some libdns
// providers put the token in their errors (libdns/duckdns: a wrong length, a failed request's URL,
// a refused answer), and Caddy's certificate manager logs those errors to the journal. The
// result is a plain error: callers here only log it.
func redact(err error, secrets ...string) error {
	if err == nil {
		return nil
	}
	msg := err.Error()
	for _, s := range secrets {
		if s == "" {
			continue
		}
		msg = strings.ReplaceAll(msg, s, "REDACTED")
		if e := url.QueryEscape(s); e != s {
			msg = strings.ReplaceAll(msg, e, "REDACTED")
		}
	}
	if msg == err.Error() {
		return err
	}
	return errors.New(msg)
}
