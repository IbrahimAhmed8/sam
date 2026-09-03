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
	"context"
	"encoding/json"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/sam/api"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// tokenPath writes a secret to a temp file and returns its path: secret
// flags only accept file (or env) input.
func tokenPath(t *testing.T, secret string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "secret")
	if err := os.WriteFile(p, []byte(secret), 0o600); err != nil {
		t.Fatalf("write secret file: %v", err)
	}
	return p
}

func startBackgroundNode(t *testing.T, nodeBin string, routerAddr string, homeDir string, args ...string) *exec.Cmd {
	t.Helper()
	t.Setenv("SAM_UNSAFE_ALLOW_LOCAL_TARGETS", "1")
	env := append(os.Environ(),
		"HOME="+homeDir,
		"XDG_CONFIG_HOME="+filepath.Join(homeDir, ".config"),
		"SAM_API_TOKEN=test-token", // per-test overrides use --api-token-path, which wins
		"SAM_UNSAFE_ALLOW_LOCAL_TARGETS=1",
	)
	allArgs := append([]string{"run", "--control-plane", routerAddr, "--jwt", "test-jwt", "--bind-addr", "127.0.0.1:0", "--allow-loopback"}, args...)
	cmd := exec.Command(nodeBin, allArgs...)
	cmd.Env = env

	logFile, err := os.Create(filepath.Join(homeDir, "node.log"))
	if err != nil {
		t.Fatalf("failed to create log file: %v", err)
	}
	cmd.Stdout = logFile
	cmd.Stderr = logFile

	if err := cmd.Start(); err != nil {
		t.Fatalf("failed to start background node: %v", err)
	}

	t.Cleanup(func() {
		if err := cmd.Process.Kill(); err != nil {
			t.Logf("warning: failed to kill background node: %v", err)
		}
		if err := logFile.Close(); err != nil {
			t.Logf("warning: failed to close log file: %v", err)
		}
	})

	return cmd
}

func waitForMCPAddr(t *testing.T, logPath string) string {
	t.Helper()
	// Generous under CI load; polling returns as soon as the line appears.
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		data, _ := os.ReadFile(logPath)
		lines := strings.Split(string(data), "\n")
		for _, line := range lines {
			if strings.Contains(line, "Starting MCP server on TCP address ") {
				parts := strings.Split(line, "Starting MCP server on TCP address ")
				if len(parts) > 1 {
					return strings.TrimSpace(parts[1])
				}
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	data, _ := os.ReadFile(logPath)
	t.Fatalf("timeout waiting for MCP addr in log: %s\n--- log contents ---\n%s", logPath, string(data))
	return ""
}

func callMCP(t *testing.T, mcpAddr string, toolName string, params map[string]any) string {
	t.Helper()
	ctx := context.Background()

	client := mcp.NewClient(&mcp.Implementation{
		Name:    "test-client",
		Version: "0.1.0",
	}, nil)

	// Custom RoundTripper to inject Authorization header for tests
	transport := http.DefaultTransport
	clientTransport := &mcp.StreamableClientTransport{
		Endpoint: "http://" + mcpAddr + "/mcp",
		HTTPClient: &http.Client{
			Transport: &authRoundTripper{
				token: "test-token", // Token used across all integration tests
				rt:    transport,
			},
		},
	}

	session, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("Failed to connect: %v", err)
	}
	defer func() {
		if err := session.Close(); err != nil {
			t.Logf("failed to close session: %v", err)
		}
	}()

	result, err := session.CallTool(ctx, &mcp.CallToolParams{
		Name:      toolName,
		Arguments: params,
	})
	if err != nil {
		t.Fatalf("CallTool failed: %v", err)
	}

	for _, content := range result.Content {
		if textContent, ok := content.(*mcp.TextContent); ok {
			return textContent.Text
		}
	}
	return ""
}

type authRoundTripper struct {
	token string
	rt    http.RoundTripper
}

func (a *authRoundTripper) RoundTrip(req *http.Request) (*http.Response, error) {
	clone := req.Clone(req.Context())
	clone.Header.Set(api.HeaderSamAuthentication, "Bearer "+a.token)
	return a.rt.RoundTrip(clone)
}

func waitForPeerInfoInLog(t *testing.T, logPath string) string {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		data, _ := os.ReadFile(logPath)
		lines := strings.Split(string(data), "\n")
		var peerID string
		var tcpAddr string
		for _, line := range lines {
			if strings.HasPrefix(line, "PeerID: ") {
				peerID = strings.TrimPrefix(line, "PeerID: ")
			}
			if strings.Contains(line, "Listening on: ") {
				parts := strings.Split(line, " ")
				for _, p := range parts {
					if strings.Contains(p, "/tcp/") {
						tcpAddr = strings.Trim(p, "[]")
					}
				}
			}
		}
		if peerID != "" && tcpAddr != "" {
			return tcpAddr + "/p2p/" + peerID
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("timeout waiting for peer info in log: %s", logPath)
	return ""
}

func TestCatalogRoutingAndFailover(t *testing.T) {
	nodeBin := buildBinary(t, "./cmd/sam-node")
	_, routerAddr := startMockRouter(t)

	homeA := t.TempDir()
	homeB := t.TempDir()
	homeC := t.TempDir()

	// Start Node A (Client)
	t.Log("Starting Node A...")
	_ = startBackgroundNode(t, nodeBin, routerAddr, homeA, "--listen", "/ip4/127.0.0.1/udp/0/quic-v1", "--listen", "/ip4/127.0.0.1/tcp/0", "--discovery-interval", "100ms")
	t.Log("Node A started.")

	// Wait for Node A to start and get its MCP address
	mcpAddrA := waitForMCPAddr(t, filepath.Join(homeA, "node.log"))

	// Start Node B (Provider 1)
	t.Log("Starting Node B...")
	cmdB := startBackgroundNode(t, nodeBin, routerAddr, homeB, "--listen", "/ip4/127.0.0.1/udp/0/quic-v1", "--listen", "/ip4/127.0.0.1/tcp/0", "--discovery-interval", "100ms")
	t.Log("Node B started.")

	// Start Node C (Provider 2)
	t.Log("Starting Node C...")
	_ = startBackgroundNode(t, nodeBin, routerAddr, homeC, "--listen", "/ip4/127.0.0.1/udp/0/quic-v1", "--listen", "/ip4/127.0.0.1/tcp/0", "--discovery-interval", "100ms")
	t.Log("Node C started.")

	// Wait for Node B and C to start and get their addresses
	addrB := waitForPeerInfoInLog(t, filepath.Join(homeB, "node.log"))
	addrC := waitForPeerInfoInLog(t, filepath.Join(homeC, "node.log"))

	// Force Node A to connect to Node B and Node C
	connectPeer(t, mcpAddrA, addrB)
	connectPeer(t, mcpAddrA, addrC)

	// Wait for them to discover each other and publish catalog by polling get_mesh_info
	t.Log("Polling for discovery...")
	deadline := time.Now().Add(2 * time.Second)
	var connected bool

	for time.Now().Before(deadline) {
		client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "0.1.0"}, nil)
		session, err := client.Connect(context.Background(), &mcp.StreamableClientTransport{
			Endpoint: "http://" + mcpAddrA + "/mcp",
			HTTPClient: &http.Client{
				Transport: &authRoundTripper{token: "test-token", rt: http.DefaultTransport},
			},
		}, nil)
		if err != nil {
			t.Logf("Poll: failed to connect: %v", err)
			time.Sleep(500 * time.Millisecond)
			continue
		}

		result, err := session.CallTool(context.Background(), &mcp.CallToolParams{Name: "get_mesh_info", Arguments: map[string]any{}})
		if closeErr := session.Close(); closeErr != nil {
			t.Logf("Poll: failed to close session: %v", closeErr)
		}
		if err != nil {
			t.Logf("Poll: CallTool failed: %v", err)
			time.Sleep(500 * time.Millisecond)
			continue
		}

		var text string
		for _, content := range result.Content {
			if textContent, ok := content.(*mcp.TextContent); ok {
				text = textContent.Text
				break
			}
		}

		t.Logf("Poll result:\n%s", text)

		var data map[string]any
		if err := json.Unmarshal([]byte(text), &data); err != nil {
			t.Logf("Failed to parse JSON: %v", err)
			time.Sleep(2 * time.Second)
			continue
		}
		connectedPeers, ok := data["connected_peers"].([]any)
		if ok && len(connectedPeers) >= 3 {
			connected = true
		}

		if connected {
			break
		}

		time.Sleep(2 * time.Second)
	}
	if !connected {
		t.Fatalf("failed to discover peers (router + 2 nodes) in time")
	}

	respData := callMCP(t, mcpAddrA, "send_message", map[string]any{"peer_id": "target-peer", "message": "hello"})
	t.Logf("First call response: %s", respData)

	// Now kill Node B and assert failover to Node C
	if err := cmdB.Process.Kill(); err != nil {
		t.Fatalf("failed to kill Node B: %v", err)
	}

	// Wait a bit for catalog update or failover to happen on next call
	time.Sleep(500 * time.Millisecond)

	respData2 := callMCP(t, mcpAddrA, "send_message", map[string]any{"peer_id": "target-peer", "message": "hello"})
	t.Logf("Second call response: %s", respData2)
}
