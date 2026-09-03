// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package integration_test

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"google.golang.org/protobuf/encoding/protojson"

	"github.com/google/sam/api"
)

// TestOpenAIFacadeCUJ covers the "point an OpenAI client at the sidecar" CUJ:
// node A registers an OpenAI-compatible inference backend, node B's sidecar
// lists the model on /v1/models and serves /v1/chat/completions for it across
// the mesh.
func TestOpenAIFacadeCUJ(t *testing.T) {
	t.Setenv("SAM_UNSAFE_ALLOW_LOCAL_TARGETS", "1")
	nodeBin := buildBinary(t, "./cmd/sam-node")
	_, hubAddr := startMockRouter(t)

	homeA := t.TempDir()
	homeB := t.TempDir()
	apiToken := "test-token"

	t.Log("Starting Node A (provider)...")
	_ = startBackgroundNode(t, nodeBin, hubAddr, homeA,
		"--listen", "/ip4/127.0.0.1/udp/0/quic-v1",
		"--listen", "/ip4/127.0.0.1/tcp/0",
		"--discovery-interval", "100ms",
		"--labels", "region=eu", // exercise the operator label claim end to end
	)
	t.Log("Starting Node B (consumer)...")
	_ = startBackgroundNode(t, nodeBin, hubAddr, homeB,
		"--listen", "/ip4/127.0.0.1/udp/0/quic-v1",
		"--listen", "/ip4/127.0.0.1/tcp/0",
		"--discovery-interval", "100ms",
	)

	apiAddrA := waitForMCPAddr(t, filepath.Join(homeA, "node.log"))
	apiAddrB := waitForMCPAddr(t, filepath.Join(homeB, "node.log"))
	waitForAPI(t, apiAddrA)
	waitForAPI(t, apiAddrB)

	addrA := waitForPeerInfoInLog(t, filepath.Join(homeA, "node.log"))
	connectPeer(t, apiAddrB, addrA)
	waitForDHTPeers(t, apiAddrA)

	// Fake OpenAI-compatible backend on node A's side.
	var sawSidecarToken, sawSamAuthHeader atomic.Bool
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.Header.Get("Authorization"), apiToken) {
			sawSidecarToken.Store(true)
		}
		if r.Header.Get(api.HeaderSamAuthentication) != "" {
			sawSamAuthHeader.Store(true)
		}
		switch r.URL.Path {
		case "/v1/models":
			_, _ = w.Write([]byte(`{"object":"list","data":[{"id":"test-model"}]}`))
		case "/v1/chat/completions":
			body, _ := io.ReadAll(r.Body)
			var req struct {
				Model string `json:"model"`
			}
			_ = json.Unmarshal(body, &req)
			if req.Model != "test-model" {
				http.Error(w, "unknown model", http.StatusNotFound)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"id":"cmpl-1","object":"chat.completion","model":"test-model",` +
				`"choices":[{"index":0,"message":{"role":"assistant","content":"hello from the mesh"}}],` +
				`"usage":{"prompt_tokens":3,"completion_tokens":5,"total_tokens":8}}`))
		default:
			http.Error(w, "not found", http.StatusNotFound)
		}
	}))
	defer backend.Close()

	registerInferenceService(t, apiAddrA, apiToken, "test-llm", backend.URL)

	// CUJ step 1: the model shows up on the consumer's /v1/models.
	waitForFacadeModel(t, apiAddrB, apiToken, "test-model")

	// CUJ step 2: a chat completion for that model is served across the mesh.
	reqBody := `{"model":"test-model","messages":[{"role":"user","content":"hi"}]}`
	req, _ := http.NewRequest("POST", "http://"+apiAddrB+"/v1/chat/completions", strings.NewReader(reqBody))
	// OpenAI SDK style: the sidecar token is the api_key in Authorization.
	req.Header.Set("Authorization", "Bearer "+apiToken)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("chat completion request failed: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("chat completion status: got %d, body: %s", resp.StatusCode, string(body))
	}
	var completion struct {
		Model   string `json:"model"`
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(body, &completion); err != nil {
		t.Fatalf("invalid completion response: %v, body: %s", err, string(body))
	}
	if len(completion.Choices) != 1 || completion.Choices[0].Message.Content != "hello from the mesh" {
		t.Fatalf("unexpected completion: %s", string(body))
	}

	// CUJ step 2b: a label requirement is enforced end to end — the provider
	// declared region=eu at enrollment, so its biscuit carries an attested
	// label fact and the consumer's label gate admits it. The region gossip
	// hint arrives via interest-scoped gossip, so poll until it propagates.
	deadline := time.Now().Add(30 * time.Second)
	for {
		req, _ = http.NewRequest("POST", "http://"+apiAddrB+"/v1/chat/completions", strings.NewReader(reqBody))
		req.Header.Set("Authorization", "Bearer "+apiToken)
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set(api.HeaderSamRequiredLabels, "region=eu")
		respEU, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("label-constrained completion request failed: %v", err)
		}
		euBody, _ := io.ReadAll(respEU.Body)
		_ = respEU.Body.Close()
		if respEU.StatusCode == http.StatusOK {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("label-constrained completion status: got %d, body: %s", respEU.StatusCode, string(euBody))
		}
		time.Sleep(200 * time.Millisecond)
	}

	// A requirement that mismatches the provider's declared label fails closed.
	req, _ = http.NewRequest("POST", "http://"+apiAddrB+"/v1/chat/completions", strings.NewReader(reqBody))
	req.Header.Set("Authorization", "Bearer "+apiToken)
	req.Header.Set(api.HeaderSamRequiredLabels, "region=us-east-1")
	respDE, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("mismatched-label completion request failed: %v", err)
	}
	defer func() { _ = respDE.Body.Close() }()
	deBody, _ := io.ReadAll(respDE.Body)
	if respDE.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("mismatched label must fail closed: got %d, body: %s", respDE.StatusCode, string(deBody))
	}

	// CUJ step 3: unknown models fail with an OpenAI-style error.
	req, _ = http.NewRequest("POST", "http://"+apiAddrB+"/v1/chat/completions",
		strings.NewReader(`{"model":"no-such-model","messages":[]}`))
	req.Header.Set("Authorization", "Bearer "+apiToken)
	resp2, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("unknown-model request failed: %v", err)
	}
	defer func() { _ = resp2.Body.Close() }()
	errBody, _ := io.ReadAll(resp2.Body)
	if resp2.StatusCode != http.StatusNotFound || !strings.Contains(string(errBody), "model_not_found") {
		t.Fatalf("unknown model: got status %d, body: %s", resp2.StatusCode, string(errBody))
	}

	// Zero-trust invariant: local gate credentials never reach the backend.
	if sawSidecarToken.Load() {
		t.Error("sidecar token leaked to the inference backend")
	}
	if sawSamAuthHeader.Load() {
		t.Errorf("%s header leaked to the inference backend", api.HeaderSamAuthentication)
	}

	t.Log("OpenAI facade CUJ test passed.")
}

func registerInferenceService(t *testing.T, apiAddr, token, serviceName, targetURL string) {
	t.Helper()
	reqData := &api.RegisterServiceRequest{
		Service: &api.ServiceInfo{
			Type:        api.ServiceType_SERVICE_TYPE_INFERENCE,
			Name:        serviceName,
			Description: "test inference backend",
		},
		Backend: &api.RegisterServiceRequest_TargetUrl{TargetUrl: targetURL},
	}
	body, err := protojson.Marshal(reqData)
	if err != nil {
		t.Fatal(err)
	}
	req, _ := http.NewRequest("POST", "http://"+apiAddr+"/sam/service/register", bytes.NewBuffer(body))
	req.Header.Set(api.HeaderSamAuthentication, "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("Failed to register inference service: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		bodyBytes, _ := io.ReadAll(resp.Body)
		t.Fatalf("Register inference service failed with status: %d, body: %s", resp.StatusCode, string(bodyBytes))
	}
}

// waitForDHTPeers polls get_mesh_info until the node sees DHT peers.
func waitForDHTPeers(t *testing.T, apiAddr string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		respData := callMCP(t, apiAddr, "get_mesh_info", map[string]any{})
		var data map[string]any
		if err := json.Unmarshal([]byte(respData), &data); err == nil {
			if dhtSize, _ := data["dht_size"].(float64); dhtSize > 0 {
				return
			}
		}
		time.Sleep(500 * time.Millisecond)
	}
	t.Fatal("DHT not ready (size 0)")
}

// waitForFacadeModel polls the consumer's /v1/models until the model appears.
func waitForFacadeModel(t *testing.T, apiAddr, token, model string) {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	var lastBody string
	for time.Now().Before(deadline) {
		req, _ := http.NewRequest("GET", "http://"+apiAddr+"/v1/models", nil)
		req.Header.Set("Authorization", "Bearer "+token)
		resp, err := http.DefaultClient.Do(req)
		if err == nil {
			body, _ := io.ReadAll(resp.Body)
			_ = resp.Body.Close()
			lastBody = string(body)
			if resp.StatusCode == http.StatusOK {
				var list struct {
					Data []struct {
						ID string `json:"id"`
					} `json:"data"`
				}
				if err := json.Unmarshal(body, &list); err == nil {
					for _, m := range list.Data {
						if m.ID == model {
							return
						}
					}
				}
			}
		}
		time.Sleep(500 * time.Millisecond)
	}
	t.Fatalf("timeout waiting for model %q on /v1/models, last response: %s", model, lastBody)
}
