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

package node

import (
	"bytes"
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/google/sam/api"
	"google.golang.org/protobuf/encoding/protojson"
)

const ssrfSecretPayload = "INTERNAL_SECRET_DATA"

func TestSSRF_LoopbackTarget(t *testing.T) {
	t.Setenv("SAM_UNSAFE_ALLOW_LOCAL_TARGETS", "")
	withRealLookupIP(t)

	internal := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/secret" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte(ssrfSecretPayload))
	}))
	_ = internal.Listener.Close()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen on loopback: %v", err)
	}
	internal.Listener = listener
	internal.Start()
	t.Cleanup(internal.Close)

	targetURL := "http://127.0.0.1:" + strconv.Itoa(listener.Addr().(*net.TCPAddr).Port)

	node := &SamNode{
		BiscuitTimeout: 500 * time.Millisecond,
		services:       NewServiceRegistry(&fakeDHT{}),
	}

	reqBody := &api.RegisterServiceRequest{
		Service: &api.ServiceInfo{
			Type:        api.ServiceType_SERVICE_TYPE_MCP,
			Name:        "ssrf-loopback-probe",
			Description: "SSRF regression probe",
		},
		Backend: &api.RegisterServiceRequest_TargetUrl{TargetUrl: targetURL},
	}
	body, err := protojson.Marshal(reqBody)
	if err != nil {
		t.Fatalf("marshal register request: %v", err)
	}

	regReq := httptest.NewRequest(http.MethodPost, "/sam/service/register", bytes.NewReader(body))
	regRR := httptest.NewRecorder()
	handleRegisterService(node, regRR, regReq)

	if regRR.Code == http.StatusOK {
		t.Fatalf("loopback target %q was accepted; SSRF defense missing", targetURL)
	}
	if node.IsServiceRegistered("ssrf-loopback-probe") {
		t.Fatal("loopback service was registered; SSRF defense missing")
	}
	if !strings.Contains(regRR.Body.String(), "invalid target address") {
		t.Fatalf("expected invalid target address error, got status %d body %q", regRR.Code, regRR.Body.String())
	}
}

func TestSSRF_LoopbackTarget_DirectHandler(t *testing.T) {
	t.Setenv("SAM_UNSAFE_ALLOW_LOCAL_TARGETS", "")
	withRealLookupIP(t)

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen on loopback: %v", err)
	}
	t.Cleanup(func() { _ = listener.Close() })

	targetURL := "http://127.0.0.1:" + strconv.Itoa(listener.Addr().(*net.TCPAddr).Port) + "/secret"

	if _, err := newReverseProxyHandler(targetURL); err == nil {
		t.Fatal("newReverseProxyHandler accepted loopback URL; SSRF defense missing")
	} else if !strings.Contains(err.Error(), "invalid target address") {
		t.Fatalf("expected invalid target address, got %v", err)
	}

	b := &baseService{
		info:    &api.ServiceInfo{Type: api.ServiceType_SERVICE_TYPE_INFERENCE, Name: "direct"},
		backend: &api.RegisterServiceRequest_TargetUrl{TargetUrl: targetURL},
	}
	if err := b.Init(context.Background()); err == nil {
		t.Fatal("baseService.Init accepted loopback URL; SSRF defense missing")
	} else if !strings.Contains(err.Error(), "invalid target address") {
		t.Fatalf("expected invalid target address, got %v", err)
	}
}
