// Ledger: a deliberately small payments service used to exercise the platform.
// Double-entry transfers, a tamper-evident (hash-chained) audit log on stdout,
// and Prometheus-format metrics for SLOs. State is in memory: this is a demo workload.
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

type transfer struct {
	From   string `json:"from"`
	To     string `json:"to"`
	Amount int64  `json:"amount_minor"` // minor units (pence/cents); never floats for money
	Ref    string `json:"ref"`
}

type ledger struct {
	mu        sync.Mutex
	balances  map[string]int64
	seen      map[string]bool // idempotency by ref
	prevHash  string
	auditOut  *log.Logger
}

func newLedger() *ledger {
	l := &ledger{
		balances: map[string]int64{"acct-treasury": 1_000_000_00},
		seen:     map[string]bool{},
		prevHash: "genesis",
		auditOut: log.New(os.Stdout, "", 0),
	}
	return l
}

// audit writes one JSON line whose hash covers the previous line, so removing or
// editing a record breaks the chain.
func (l *ledger) audit(event string, fields map[string]any) {
	rec := map[string]any{"ts": time.Now().UTC().Format(time.RFC3339Nano), "event": event, "prev": l.prevHash}
	for k, v := range fields {
		rec[k] = v
	}
	body, _ := json.Marshal(rec)
	sum := sha256.Sum256(body)
	l.prevHash = hex.EncodeToString(sum[:])
	rec["hash"] = l.prevHash
	out, _ := json.Marshal(rec)
	l.auditOut.Println(string(out))
}

func (l *ledger) apply(t transfer) (int, string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	switch {
	case t.Ref == "" || t.From == "" || t.To == "" || t.From == t.To || t.Amount <= 0:
		l.audit("transfer_rejected", map[string]any{"reason": "invalid", "ref": t.Ref})
		return http.StatusBadRequest, "invalid transfer"
	case l.seen[t.Ref]:
		return http.StatusOK, "duplicate ignored"
	case l.balances[t.From] < t.Amount:
		l.audit("transfer_rejected", map[string]any{"reason": "insufficient_funds", "ref": t.Ref, "from": t.From})
		return http.StatusUnprocessableEntity, "insufficient funds"
	}
	l.balances[t.From] -= t.Amount
	l.balances[t.To] += t.Amount
	l.seen[t.Ref] = true
	l.audit("transfer_applied", map[string]any{"ref": t.Ref, "from": t.From, "to": t.To, "amount_minor": t.Amount})
	return http.StatusCreated, "ok"
}

var (
	reqTotal  = map[string]*atomic.Int64{} // keyed by status class, filled in init
	latBucket = []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1}
	latCounts = make([]atomic.Int64, 9) // len(latBucket)+1 (+Inf)
	latSumUs  atomic.Int64
)

func init() {
	for _, c := range []string{"2xx", "4xx", "5xx"} {
		reqTotal[c] = new(atomic.Int64)
	}
}

type statusWriter struct {
	http.ResponseWriter
	code int
}

func (s *statusWriter) WriteHeader(c int) { s.code = c; s.ResponseWriter.WriteHeader(c) }

func instrument(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, code: 200}
		next.ServeHTTP(sw, r)
		d := time.Since(start).Seconds()
		reqTotal[fmt.Sprintf("%dxx", sw.code/100)].Add(1)
		latSumUs.Add(int64(d * 1e6))
		i := 0
		for i < len(latBucket) && d > latBucket[i] {
			i++
		}
		latCounts[i].Add(1)
	})
}

func metrics(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	for _, c := range []string{"2xx", "4xx", "5xx"} {
		fmt.Fprintf(w, "ledger_http_requests_total{code=%q} %d\n", c, reqTotal[c].Load())
	}
	var cum int64
	for i, le := range latBucket {
		cum += latCounts[i].Load()
		fmt.Fprintf(w, "ledger_http_request_duration_seconds_bucket{le=\"%g\"} %d\n", le, cum)
	}
	cum += latCounts[len(latBucket)].Load()
	fmt.Fprintf(w, "ledger_http_request_duration_seconds_bucket{le=\"+Inf\"} %d\n", cum)
	fmt.Fprintf(w, "ledger_http_request_duration_seconds_count %d\n", cum)
	fmt.Fprintf(w, "ledger_http_request_duration_seconds_sum %g\n", float64(latSumUs.Load())/1e6)
}

func main() {
	l := newLedger()
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { fmt.Fprint(w, "ok") })
	mux.HandleFunc("GET /metrics", metrics)
	mux.HandleFunc("GET /version", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(w, os.Getenv("APP_VERSION"))
	})
	mux.HandleFunc("POST /transfers", func(w http.ResponseWriter, r *http.Request) {
		var t transfer
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&t); err != nil {
			http.Error(w, "bad json", http.StatusBadRequest)
			return
		}
		code, msg := l.apply(t)
		w.WriteHeader(code)
		fmt.Fprintln(w, msg)
	})
	mux.HandleFunc("GET /accounts/{id}", func(w http.ResponseWriter, r *http.Request) {
		l.mu.Lock()
		b, ok := l.balances[r.PathValue("id")]
		l.mu.Unlock()
		if !ok {
			http.NotFound(w, r)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"id": r.PathValue("id"), "balance_minor": b})
	})

	addr := ":8080"
	log.Printf("ledger listening on %s", addr)
	log.Fatal((&http.Server{
		Addr: addr, Handler: instrument(mux),
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second,
	}).ListenAndServe())
}
