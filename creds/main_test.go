package main

import (
	"testing"
	"time"
)

func TestContainerCredsPayloadIncludesExpiration(t *testing.T) {
	c := &Creds{
		AccessKeyId:     "ak",
		SecretAccessKey: "sk",
		SessionToken:    "token",
		Expiration:      "2026-07-27T12:00:00Z",
	}
	payload := containerCredsPayload(c)
	if payload["AccessKeyId"] != "ak" {
		t.Fatalf("AccessKeyId mismatch: %#v", payload)
	}
	if payload["SecretAccessKey"] != "sk" {
		t.Fatalf("SecretAccessKey mismatch: %#v", payload)
	}
	if payload["Token"] != "token" {
		t.Fatalf("Token mismatch: %#v", payload)
	}
	if payload["Expiration"] != c.Expiration {
		t.Fatalf("Expiration mismatch: %#v", payload)
	}
}

func TestContainerCredsPayloadAddsExpirationForStaticCreds(t *testing.T) {
	c := &Creds{AccessKeyId: "ak", SecretAccessKey: "sk"}
	payload := containerCredsPayload(c)
	exp, ok := payload["Expiration"].(string)
	if !ok || exp == "" {
		t.Fatalf("static credentials payload must include Expiration: %#v", payload)
	}
	if _, err := time.Parse(time.RFC3339, exp); err != nil {
		t.Fatalf("Expiration is not RFC3339: %q", exp)
	}
}
