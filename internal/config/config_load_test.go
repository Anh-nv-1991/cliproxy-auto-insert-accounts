package config

import (
	"os"
	"testing"
)

func TestExpandEnvRefs(t *testing.T) {
	t.Setenv("TEST_EXPAND_KEY", "secret-value")

	tests := []struct {
		name  string
		input string
		want  string
	}{
		{
			name:  "expands defined variable",
			input: "api-keys:\n  - \"${TEST_EXPAND_KEY}\"\n",
			want:  "api-keys:\n  - \"secret-value\"\n",
		},
		{
			name:  "keeps undefined variable as-is",
			input: "api-keys:\n  - \"${TEST_EXPAND_MISSING}\"\n",
			want:  "api-keys:\n  - \"${TEST_EXPAND_MISSING}\"\n",
		},
		{
			name:  "leaves bare dollar sequences untouched",
			input: "secret-key: \"$2a$10$abcdefgh\"\n",
			want:  "secret-key: \"$2a$10$abcdefgh\"\n",
		},
		{
			name:  "leaves unclosed placeholder untouched",
			input: "api-keys:\n  - \"${TEST_EXPAND_KEY\"\n",
			want:  "api-keys:\n  - \"${TEST_EXPAND_KEY\"\n",
		},
		{
			name:  "no references passthrough",
			input: "port: 8317\n",
			want:  "port: 8317\n",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := string(expandEnvRefs([]byte(tt.input))); got != tt.want {
				t.Errorf("expandEnvRefs() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestLoadConfigExpandsEnvRefs(t *testing.T) {
	t.Setenv("TEST_EXPAND_API_KEY", "loaded-key")

	content := "port: 8317\napi-keys:\n  - \"${TEST_EXPAND_API_KEY}\"\n"
	path := t.TempDir() + "/config.yaml"
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("failed to write temp config: %v", err)
	}

	cfg, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("LoadConfig() error = %v", err)
	}
	if len(cfg.APIKeys) != 1 || cfg.APIKeys[0] != "loaded-key" {
		t.Errorf("APIKeys = %v, want [loaded-key]", cfg.APIKeys)
	}
}
