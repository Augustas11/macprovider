// Command faultproxy is a #1690 e2e fault injector for the gateway ->
// coordinator hop (SPEC-022 R-12.8 negotiated settlement finality). It is a
// streaming HTTP/1.1 reverse proxy that forwards every request unchanged and
// rewrites only the coordinator's settlement finality on chat 200s, per the
// mode read from -mode-file on every request (so a scenario switches modes
// without restarting anything):
//
//	pass            forward unchanged (trailers included)
//	strip-trailers  drop the Trailer declaration and every trailer
//	strip-outcome   drop the seven outcome trailers (declaration and value),
//	                keep the finality MAC trailer
//	tamper          flip X-MacProvider-Settlement-Reason (trailer, or header
//	                when the tuple travels in headers) to a different value
//	drop-after-body forward the full body, then abort the connection before
//	                the terminating chunk/trailers
//
// Every rewrite is logged with the coordinator request id. Test scaffolding
// only; it binds loopback.
package main

import (
	"flag"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
	"time"
)

var outcomeNames = []string{
	"X-MacProvider-Settlement-Outcome",
	"X-MacProvider-Settlement-Receipt-Result",
	"X-MacProvider-Settlement-Reason",
	"X-MacProvider-Settlement-Closed",
	"X-MacProvider-Settlement-Mode",
	"X-MacProvider-Settlement-Policy-Version",
	"X-MacProvider-Settlement-Pending-Deadline-Unix-Ms",
}

const macName = "X-MacProvider-Settlement-Finality-Mac"

var hopByHop = map[string]bool{
	"Connection": true, "Proxy-Connection": true, "Keep-Alive": true, "Proxy-Authenticate": true,
	"Proxy-Authorization": true, "Te": true, "Trailer": true, "Transfer-Encoding": true, "Upgrade": true,
}

var seq atomic.Int64

func main() {
	listen := flag.String("listen", "127.0.0.1:8453", "listen address")
	upstream := flag.String("upstream", "http://127.0.0.1:8443", "coordinator buyer mux")
	modeFile := flag.String("mode-file", "/run/e2e-faultproxy/mode", "file holding the current mode")
	flag.Parse()
	log.SetFlags(log.LstdFlags | log.Lmicroseconds | log.LUTC)
	tr := &http.Transport{Proxy: nil, DialContext: (&net.Dialer{Timeout: 10 * time.Second}).DialContext,
		MaxIdleConnsPerHost: 64, DisableCompression: true, ResponseHeaderTimeout: 0}
	h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mode := readMode(*modeFile)
		n := seq.Add(1)
		out, err := http.NewRequestWithContext(r.Context(), r.Method, strings.TrimRight(*upstream, "/")+r.URL.RequestURI(), r.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		out.ContentLength = r.ContentLength
		for k, vs := range r.Header {
			if hopByHop[http.CanonicalHeaderKey(k)] {
				continue
			}
			for _, v := range vs {
				out.Header.Add(k, v)
			}
		}
		out.Header.Set("Te", "trailers")
		resp, err := tr.RoundTrip(out)
		if err != nil {
			log.Printf("#%d %s %s upstream error: %v", n, r.Method, r.URL.Path, err)
			http.Error(w, "upstream error", http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()
		chat := r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/chat/completions") && resp.StatusCode == http.StatusOK
		if !chat {
			mode = "pass"
		}
		rid := resp.Header.Get("X-MacProvider-Internal-Request-ID")
		for k, vs := range resp.Header {
			if hopByHop[http.CanonicalHeaderKey(k)] {
				continue
			}
			for _, v := range vs {
				w.Header().Add(k, v)
			}
		}
		// Declared trailer names (net/http moves them into resp.Trailer).
		var declared []string
		for k := range resp.Trailer {
			declared = append(declared, http.CanonicalHeaderKey(k))
		}
		keep := func(name string) bool {
			switch mode {
			case "strip-trailers":
				return false
			case "strip-outcome":
				for _, o := range outcomeNames {
					if strings.EqualFold(o, name) {
						return false
					}
				}
			}
			return true
		}
		var kept []string
		for _, name := range declared {
			if keep(name) {
				kept = append(kept, name)
				w.Header().Add("Trailer", name)
			}
		}
		if mode == "tamper" && len(declared) == 0 && w.Header().Get("X-MacProvider-Settlement-Reason") != "" || mode == "tamper" && len(declared) == 0 && w.Header().Get("X-MacProvider-Settlement-Mode") != "" {
			old := w.Header().Get("X-MacProvider-Settlement-Reason")
			w.Header().Set("X-MacProvider-Settlement-Reason", tampered(old))
			log.Printf("#%d rid=%s mode=tamper header reason %q -> %q", n, rid, old, tampered(old))
		}
		log.Printf("#%d rid=%s %s %s status=%d mode=%s declared=%v kept=%v", n, rid, r.Method, r.URL.Path, resp.StatusCode, mode, declared, kept)
		w.WriteHeader(resp.StatusCode)
		fl, _ := w.(http.Flusher)
		buf := make([]byte, 32*1024)
		for {
			m, rerr := resp.Body.Read(buf)
			if m > 0 {
				if _, werr := w.Write(buf[:m]); werr != nil {
					log.Printf("#%d rid=%s downstream write error: %v", n, rid, werr)
					return
				}
				if fl != nil {
					fl.Flush()
				}
			}
			if rerr == io.EOF {
				break
			}
			if rerr != nil {
				log.Printf("#%d rid=%s upstream body error: %v", n, rid, rerr)
				panic(http.ErrAbortHandler)
			}
		}
		if mode == "drop-after-body" {
			log.Printf("#%d rid=%s mode=drop-after-body: aborting after body", n, rid)
			panic(http.ErrAbortHandler)
		}
		for _, name := range kept {
			v := resp.Trailer.Get(name)
			if mode == "tamper" && strings.EqualFold(name, "X-MacProvider-Settlement-Reason") {
				log.Printf("#%d rid=%s mode=tamper trailer reason %q -> %q", n, rid, v, tampered(v))
				v = tampered(v)
			}
			w.Header().Set(name, v)
		}
		var got []string
		for _, name := range declared {
			got = append(got, name+"="+short(resp.Trailer.Get(name)))
		}
		log.Printf("#%d rid=%s upstream trailers: %s", n, rid, strings.Join(got, " "))
	})
	log.Printf("faultproxy listening on %s -> %s (mode file %s)", *listen, *upstream, *modeFile)
	srv := &http.Server{Addr: *listen, Handler: h, ReadHeaderTimeout: 30 * time.Second}
	log.Fatal(srv.ListenAndServe())
}

func tampered(v string) string {
	if v == "verified_settlement" {
		return "tampered_reason"
	}
	return "verified_settlement"
}

func short(v string) string {
	if len(v) > 16 {
		return v[:16] + "…"
	}
	return v
}

func readMode(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return "pass"
	}
	m := strings.TrimSpace(string(b))
	switch m {
	case "pass", "strip-trailers", "strip-outcome", "tamper", "drop-after-body":
		return m
	}
	return "pass"
}
