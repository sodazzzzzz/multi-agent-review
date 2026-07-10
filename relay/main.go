// Command relay — тонкое реле для multi-agent-review: превращает события GitHub App
// и клики по реран-ссылке в repository_dispatch на репозитории бота. Логики ревью в
// нём нет — вся она в .github/workflows/app-review.yml. Реле только триггерит Actions,
// поэтому его падение не влияет на крон/секреты.
//
// Эндпоинты:
//
//	POST /webhook  — приёмник App-вебхука. Проверяет HMAC (WEBHOOK_SECRET). На
//	                 pull_request opened/reopened/ready_for_review → dispatch "app-review".
//	                 synchronize (новые коммиты) НЕ триггерит — авто-перепрогонов нет.
//	GET  /rerun    — цель реран-ссылки из обзора. Проверяет подпись (RERUN_SECRET) →
//	                 dispatch "app-review-rerun" → 302 обратно в PR.
//	GET  /healthz  — liveness для Dokploy (дёшево: «процесс жив», без внешних вызовов).
//	GET  /readyz   — readiness: лёгкий вызов к GitHub тем же dispatch-токеном. 200 только
//	                 если GitHub достижим И токен валиден, т.е. диспатч реально возможен.
//	                 Внешний аптайм-алерт вешать сюда, а не на /healthz.
//	GET  /metrics  — JSON-счётчики диспатча (ok/fail, last_success/last_fail, healthy).
//	                 Для простого аптайм-монитора: алерт по "healthy":false (последняя
//	                 попытка диспатча упала и не восстановилась). НЕ по устареванию
//	                 last_success — тихий период без PR это не поломка.
package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	// PAT (fine-grained, Contents: Read & write на dispatchRepo) для repository_dispatch.
	dispatchToken = os.Getenv("GITHUB_DISPATCH_TOKEN")
	// Куда слать dispatch — репозиторий бота (где живёт app-review.yml).
	dispatchRepo = getenv("DISPATCH_REPO", "sodazzzzzz/multi-agent-review")
	// База GitHub API — переменной, чтобы тесты могли подменить на httptest-сервер.
	githubAPI = getenv("GITHUB_API_URL", "https://api.github.com")
	// Секрет App-вебхука (тот же, что в настройках GitHub App).
	webhookSecret = []byte(os.Getenv("WEBHOOK_SECRET"))
	// Ключ подписи реран-ссылок (общий с аггрегатором, который эти ссылки строит).
	rerunSecret = []byte(os.Getenv("RERUN_SECRET"))
	port        = getenv("PORT", "8080")
)

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	if len(webhookSecret) == 0 || len(rerunSecret) == 0 || dispatchToken == "" {
		log.Fatal("нужны env: WEBHOOK_SECRET, RERUN_SECRET, GITHUB_DISPATCH_TOKEN")
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/webhook", handleWebhook)
	mux.HandleFunc("/rerun", handleRerun)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "ok")
	})
	mux.HandleFunc("/readyz", handleReadyz)
	mux.HandleFunc("/metrics", handleMetrics)

	srv := &http.Server{
		Addr:         ":" + port,
		Handler:      mux,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
	}
	log.Printf("multi-agent-review relay на :%s → dispatch %s", port, dispatchRepo)
	log.Fatal(srv.ListenAndServe())
}

// --- webhook (событие GitHub App) ---

func handleWebhook(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 2<<20)) // 2 МБ хватит на pull_request
	if err != nil {
		http.Error(w, "read error", http.StatusBadRequest)
		return
	}
	if !validWebhookSig(r.Header.Get("X-Hub-Signature-256"), body) {
		http.Error(w, "bad signature", http.StatusUnauthorized)
		return
	}

	switch r.Header.Get("X-GitHub-Event") {
	case "ping":
		w.WriteHeader(http.StatusNoContent)
		return
	case "pull_request":
		// обрабатываем ниже
	default:
		w.WriteHeader(http.StatusNoContent) // прочие события игнорируем
		return
	}

	var p struct {
		Action      string `json:"action"`
		Number      int    `json:"number"`
		PullRequest struct {
			Draft bool `json:"draft"`
		} `json:"pull_request"`
		Repository struct {
			FullName string `json:"full_name"`
		} `json:"repository"`
	}
	if err := json.Unmarshal(body, &p); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}

	if !shouldReview(p.Action, p.PullRequest.Draft) {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	// dispatch() сам логирует исход и пишет метрику.
	if err := dispatch("app-review", p.Repository.FullName, p.Number); err != nil {
		http.Error(w, "dispatch failed", http.StatusBadGateway)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// shouldReview — брать ли PR в ревью по вебхуку. Черновики (draft) НЕ берём на opened/
// reopened — дождёмся ready_for_review (draft→ready). synchronize (новые коммиты) и прочие
// действия — нет (авто-перепрогонов нет; реран только по ссылке).
func shouldReview(action string, draft bool) bool {
	switch action {
	case "ready_for_review":
		return true
	case "opened", "reopened":
		return !draft
	default:
		return false
	}
}

func validWebhookSig(header string, body []byte) bool {
	const prefix = "sha256="
	if !strings.HasPrefix(header, prefix) {
		return false
	}
	want, err := hex.DecodeString(strings.TrimPrefix(header, prefix))
	if err != nil {
		return false
	}
	mac := hmac.New(sha256.New, webhookSecret)
	mac.Write(body)
	return hmac.Equal(want, mac.Sum(nil))
}

// --- rerun (клик по ссылке из обзора) ---

func handleRerun(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	repo, pr, sig := q.Get("repo"), q.Get("pr"), q.Get("sig")
	if repo == "" || pr == "" || sig == "" {
		http.Error(w, "missing repo/pr/sig", http.StatusBadRequest)
		return
	}
	if !validRerunSig(repo, pr, sig) {
		http.Error(w, "bad signature", http.StatusUnauthorized)
		return
	}
	n, err := strconv.Atoi(pr)
	if err != nil {
		http.Error(w, "bad pr", http.StatusBadRequest)
		return
	}
	if err := dispatch("app-review-rerun", repo, n); err != nil {
		http.Error(w, "dispatch failed", http.StatusBadGateway)
		return
	}
	// Возвращаем пользователя в PR — реран пойдёт фоном (Actions, ~минуты).
	http.Redirect(w, r, fmt.Sprintf("https://github.com/%s/pull/%d", repo, n), http.StatusFound)
}

// Подпись реран-ссылки: HMAC-SHA256(RERUN_SECRET, "owner/repo#pr") в hex. Ровно так же
// её строит аггрегатор (Aggregator.Render). Сравнение — постоянное по времени.
func validRerunSig(repo, pr, sig string) bool {
	got, err := hex.DecodeString(sig)
	if err != nil {
		return false
	}
	mac := hmac.New(sha256.New, rerunSecret)
	mac.Write([]byte(repo + "#" + pr))
	return subtle.ConstantTimeCompare(got, mac.Sum(nil)) == 1
}

// --- readiness (глубокая проверка: возможен ли диспатч прямо сейчас) ---

// /healthz (liveness) отвечает ok, даже когда реле не достучится до GitHub или токен
// протух — то есть ровно когда диспатчи молча падают. /readyz закрывает эту слепую зону:
// делает лёгкий аутентифицированный вызов к GitHub тем же dispatchToken.
const readyTTL = 5 * time.Second // кэш, чтобы частый опрос монитором не бил по GitHub

var (
	readyMu        sync.Mutex
	readyCheckedAt time.Time
	readyErr       error // nil → готовы диспатчить
)

func handleReadyz(w http.ResponseWriter, _ *http.Request) {
	if err := checkReady(); err != nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = io.WriteString(w, "not ready: "+err.Error())
		return
	}
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, "ready")
}

// checkReady — результат probeGitHub, кэшированный на readyTTL.
func checkReady() error {
	readyMu.Lock()
	defer readyMu.Unlock()
	if !readyCheckedAt.IsZero() && time.Since(readyCheckedAt) < readyTTL {
		return readyErr
	}
	readyErr = probeGitHub()
	readyCheckedAt = time.Now()
	return readyErr
}

// probeGitHub — GET /rate_limit тем же токеном, что и dispatch. Квоту не тратит; 200
// означает «GitHub достижим и dispatchToken валиден» → диспатч пройдёт.
func probeGitHub() error {
	req, err := http.NewRequest(http.MethodGet, githubAPI+"/rate_limit", nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+dispatchToken)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")

	resp, err := (&http.Client{Timeout: 3 * time.Second}).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<10))
		return fmt.Errorf("github %s: %s", resp.Status, b)
	}
	return nil
}

// --- метрики диспатча (для простого аптайм-монитора: алерт по "healthy":false) ---

type metricsState struct {
	mu          sync.Mutex
	ok, fail    int64
	lastSuccess int64 // unix, справочно
	lastFail    int64 // unix, справочно
	lastOK      bool  // исход последней попытки
	any         bool  // была ли хоть одна попытка
}

var metrics metricsState

func (m *metricsState) record(ok bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := time.Now().Unix()
	m.any, m.lastOK = true, ok
	if ok {
		m.ok++
		m.lastSuccess = now
	} else {
		m.fail++
		m.lastFail = now
	}
}

func handleMetrics(w http.ResponseWriter, _ *http.Request) {
	metrics.mu.Lock()
	// healthy=false только если последняя попытка упала и не восстановилась. НЕ по
	// устареванию last_success: тихий период без PR — не поломка.
	resp := map[string]any{
		"dispatch":          map[string]int64{"ok": metrics.ok, "fail": metrics.fail},
		"last_success_unix": metrics.lastSuccess,
		"last_fail_unix":    metrics.lastFail,
		"healthy":           !metrics.any || metrics.lastOK,
	}
	metrics.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

// --- repository_dispatch на репозиторий бота ---

// dispatch триггерит repository_dispatch, пишет метрику и структурный лог исхода
// (единая точка для вебхук- и реран-путей).
func dispatch(eventType, repo string, pr int) error {
	status, err := postDispatch(eventType, repo, pr)
	metrics.record(err == nil)
	if err != nil {
		log.Printf("dispatch outcome=fail event=%s repo=%s pr=%d status=%d err=%q", eventType, repo, pr, status, err)
	} else {
		log.Printf("dispatch outcome=ok event=%s repo=%s pr=%d status=%d", eventType, repo, pr, status)
	}
	return err
}

// postDispatch — сам HTTP-вызов; возвращает HTTP-статус (0 при сетевой ошибке) и ошибку.
func postDispatch(eventType, repo string, pr int) (int, error) {
	payload, _ := json.Marshal(map[string]any{
		"event_type":     eventType,
		"client_payload": map[string]any{"repo": repo, "pr": pr},
	})
	req, err := http.NewRequest(http.MethodPost,
		githubAPI+"/repos/"+dispatchRepo+"/dispatches", bytes.NewReader(payload))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Authorization", "Bearer "+dispatchToken)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	req.Header.Set("Content-Type", "application/json")

	resp, err := (&http.Client{Timeout: 10 * time.Second}).Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<10))
		return resp.StatusCode, fmt.Errorf("dispatch status %d: %s", resp.StatusCode, b)
	}
	return resp.StatusCode, nil
}
