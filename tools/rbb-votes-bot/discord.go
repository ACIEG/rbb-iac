package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"time"
)

// Envia uma mensagem por webhook do Discord. Vazio = só registra no log (modo de teste).
func (b *Bot) post(webhook, content string) {
	if content == "" {
		return
	}
	log.Printf("[mensagem] %s", content)
	if webhook == "" {
		return
	}
	body, _ := json.Marshal(map[string]any{"content": content, "username": b.cfg.BotName, "allowed_mentions": map[string]any{"parse": []string{}}})
	for attempt := 1; attempt <= 3; attempt++ {
		resp, err := http.Post(webhook, "application/json", bytes.NewReader(body))
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode < 300 {
				return
			}
			if resp.StatusCode == 429 {
				time.Sleep(time.Duration(attempt*3) * time.Second)
				continue
			}
			err = fmt.Errorf("http %d", resp.StatusCode)
		}
		log.Printf("discord: falha ao enviar (%v), tentativa %d", err, attempt)
		time.Sleep(time.Duration(attempt*2) * time.Second)
	}
}

// Canal da rede (factual) e canal da organização (avisos que nos dizem respeito)
func (b *Bot) postNetwork(msg string) { b.post(b.cfg.WebhookNetwork, msg) }
func (b *Bot) postOrg(msg string)     { b.post(b.cfg.WebhookOrg, msg) }
