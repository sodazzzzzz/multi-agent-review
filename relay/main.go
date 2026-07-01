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
//	GET  /healthz  — проверка живости для Dokploy.
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
	"time"
)

var (
	// PAT (fine-grained, Contents: Read & write на dispatchRepo) для repository_dispatch.
	dispatchToken = os.Getenv("GITHUB_DISPATCH_TOKEN")
	// Куда слать dispatch — репозиторий бота (где живёт app-review.yml).
	dispatchRepo = getenv("DISPATCH_REPO", "sodazzzzzz/multi-agent-review")
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
		Action     string `json:"action"`
		Number     int    `json:"number"`
		Repository struct {
			FullName string `json:"full_name"`
		} `json:"repository"`
	}
	if err := json.Unmarshal(body, &p); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}

	// Только открытие/переоткрытие/готовность из черновика. synchronize (новые коммиты)
	// НЕ триггерит — авто-перепрогонов быть не должно (реран только вручную по ссылке).
	switch p.Action {
	case "opened", "reopened", "ready_for_review":
	default:
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if err := dispatch("app-review", p.Repository.FullName, p.Number); err != nil {
		log.Printf("dispatch app-review failed: %v", err)
		http.Error(w, "dispatch failed", http.StatusBadGateway)
		return
	}
	log.Printf("review dispatched: %s#%d (%s)", p.Repository.FullName, p.Number, p.Action)
	w.WriteHeader(http.StatusNoContent)
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
		log.Printf("dispatch rerun failed: %v", err)
		http.Error(w, "dispatch failed", http.StatusBadGateway)
		return
	}
	log.Printf("rerun dispatched: %s#%d", repo, n)
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

// --- repository_dispatch на репозиторий бота ---

func dispatch(eventType, repo string, pr int) error {
	payload, _ := json.Marshal(map[string]any{
		"event_type":     eventType,
		"client_payload": map[string]any{"repo": repo, "pr": pr},
	})
	req, err := http.NewRequest(http.MethodPost,
		"https://api.github.com/repos/"+dispatchRepo+"/dispatches", bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+dispatchToken)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	req.Header.Set("Content-Type", "application/json")

	resp, err := (&http.Client{Timeout: 10 * time.Second}).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<10))
		return fmt.Errorf("dispatch status %d: %s", resp.StatusCode, b)
	}
	return nil
}
