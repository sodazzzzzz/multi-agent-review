package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestShouldReview(t *testing.T) {
	cases := []struct {
		action string
		draft  bool
		want   bool
	}{
		{"opened", false, true},           // обычный PR — ревьюим
		{"opened", true, false},           // черновик — НЕ ревьюим
		{"reopened", false, true},         // переоткрыт готовым — ревьюим
		{"reopened", true, false},         // переоткрыт черновиком — НЕ ревьюим
		{"ready_for_review", false, true}, // draft→ready — ревьюим
		{"ready_for_review", true, true},  // действие само означает выход из черновика
		{"synchronize", false, false},     // новые коммиты — НЕ ревьюим (авто-перепрогонов нет)
		{"closed", false, false},          // прочее — нет
		{"edited", false, false},
		{"converted_to_draft", false, false},
	}
	for _, c := range cases {
		if got := shouldReview(c.action, c.draft); got != c.want {
			t.Errorf("shouldReview(%q, draft=%v) = %v, want %v", c.action, c.draft, got, c.want)
		}
	}
}

// resetReadyCache — сбрасывает кэш readiness между кейсами (white-box).
func resetReadyCache() {
	readyMu.Lock()
	readyCheckedAt = time.Time{}
	readyErr = nil
	readyMu.Unlock()
}

func TestReadyz(t *testing.T) {
	cases := []struct {
		name       string
		ghStatus   int // статус, который отдаёт фейковый GitHub на /rate_limit
		wantStatus int // ожидаемый статус /readyz
	}{
		{"github ok → ready", http.StatusOK, http.StatusOK},
		{"token невалиден (401) → not ready", http.StatusUnauthorized, http.StatusServiceUnavailable},
		{"github 5xx → not ready", http.StatusInternalServerError, http.StatusServiceUnavailable},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			gotProbe := false
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/rate_limit" {
					t.Errorf("probe дёрнул %q, ждали /rate_limit", r.URL.Path)
				}
				if h := r.Header.Get("Authorization"); h != "Bearer test-token" {
					t.Errorf("Authorization = %q, ждали Bearer-токен", h)
				}
				gotProbe = true
				w.WriteHeader(c.ghStatus)
			}))
			defer srv.Close()

			oldAPI, oldTok := githubAPI, dispatchToken
			githubAPI, dispatchToken = srv.URL, "test-token"
			resetReadyCache()
			defer func() { githubAPI, dispatchToken = oldAPI, oldTok; resetReadyCache() }()

			rec := httptest.NewRecorder()
			handleReadyz(rec, httptest.NewRequest(http.MethodGet, "/readyz", nil))

			if !gotProbe {
				t.Fatal("probeGitHub не сходил в GitHub")
			}
			if rec.Code != c.wantStatus {
				t.Errorf("/readyz = %d, want %d (body=%q)", rec.Code, c.wantStatus, rec.Body.String())
			}
		})
	}
}

func resetMetrics() {
	metrics.mu.Lock()
	metrics.ok, metrics.fail, metrics.lastSuccess, metrics.lastFail = 0, 0, 0, 0
	metrics.any, metrics.lastOK = false, false
	metrics.mu.Unlock()
}

func TestMetricsEndpoint(t *testing.T) {
	decode := func() map[string]any {
		rec := httptest.NewRecorder()
		handleMetrics(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("/metrics = %d, want 200", rec.Code)
		}
		var m map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &m); err != nil {
			t.Fatalf("невалидный JSON: %v", err)
		}
		return m
	}

	resetMetrics()
	defer resetMetrics()

	// Пусто: попыток не было → healthy=true.
	if m := decode(); m["healthy"] != true {
		t.Errorf("без попыток healthy=%v, want true", m["healthy"])
	}

	// Последняя попытка упала → healthy=false, fail=1.
	metrics.record(false)
	m := decode()
	if m["healthy"] != false {
		t.Errorf("после fail healthy=%v, want false", m["healthy"])
	}
	if d := m["dispatch"].(map[string]any); d["fail"].(float64) != 1 {
		t.Errorf("fail=%v, want 1", d["fail"])
	}

	// Успех после фейла → восстановились: healthy=true.
	metrics.record(true)
	if m := decode(); m["healthy"] != true {
		t.Errorf("после восстановления healthy=%v, want true", m["healthy"])
	}

	// Новый фейл после успеха → снова healthy=false (тай по секунде не должен ломать сигнал).
	metrics.record(true)
	metrics.record(false)
	if m := decode(); m["healthy"] != false {
		t.Errorf("fail после ok в ту же секунду: healthy=%v, want false", m["healthy"])
	}
}

// checkReady кэширует результат на readyTTL: второй вызов не должен снова бить по GitHub.
func TestReadyCacheHit(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls++
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	oldAPI, oldTok := githubAPI, dispatchToken
	githubAPI, dispatchToken = srv.URL, "test-token"
	resetReadyCache()
	defer func() { githubAPI, dispatchToken = oldAPI, oldTok; resetReadyCache() }()

	for range 3 {
		if err := checkReady(); err != nil {
			t.Fatalf("checkReady вернул ошибку: %v", err)
		}
	}
	if calls != 1 {
		t.Errorf("probe сходил в GitHub %d раз(а), ждали 1 (кэш)", calls)
	}
}
