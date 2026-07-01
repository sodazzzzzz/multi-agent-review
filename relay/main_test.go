package main

import "testing"

func TestShouldReview(t *testing.T) {
	cases := []struct {
		action string
		draft  bool
		want   bool
	}{
		{"opened", false, true},          // обычный PR — ревьюим
		{"opened", true, false},          // черновик — НЕ ревьюим
		{"reopened", false, true},        // переоткрыт готовым — ревьюим
		{"reopened", true, false},        // переоткрыт черновиком — НЕ ревьюим
		{"ready_for_review", false, true}, // draft→ready — ревьюим
		{"ready_for_review", true, true},  // действие само означает выход из черновика
		{"synchronize", false, false},    // новые коммиты — НЕ ревьюим (авто-перепрогонов нет)
		{"closed", false, false},         // прочее — нет
		{"edited", false, false},
		{"converted_to_draft", false, false},
	}
	for _, c := range cases {
		if got := shouldReview(c.action, c.draft); got != c.want {
			t.Errorf("shouldReview(%q, draft=%v) = %v, want %v", c.action, c.draft, got, c.want)
		}
	}
}
