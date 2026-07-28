package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"testing"
	"time"
)

// 用与 authd 相同的参数独立地算一个客户端 SigV4 签名（模拟 boto3/aws-cli）。
func clientSign(secret, ak, method, uri, host, amzDate, contentSha string) string {
	dateStamp := amzDate[:8]
	signed := []string{"host", "x-amz-content-sha256", "x-amz-date"}
	canonicalHeaders := "host:" + host + "\n" +
		"x-amz-content-sha256:" + contentSha + "\n" +
		"x-amz-date:" + amzDate + "\n"
	rawPath, rawQuery := uri, ""
	for i := 0; i < len(uri); i++ {
		if uri[i] == '?' {
			rawPath, rawQuery = uri[:i], uri[i+1:]
			break
		}
	}
	cr := method + "\n" + rawPath + "\n" + canonicalQueryString(rawQuery) + "\n" +
		canonicalHeaders + "\n" + join(signed) + "\n" + contentSha
	scope := dateStamp + "/" + region + "/" + service + "/aws4_request"
	sts := "AWS4-HMAC-SHA256\n" + amzDate + "\n" + scope + "\n" + sha256Hex(cr)
	kDate := hmacRaw([]byte("AWS4"+secret), dateStamp)
	kRegion := hmacRaw(kDate, region)
	kService := hmacRaw(kRegion, service)
	kSigning := hmacRaw(kService, "aws4_request")
	sig := hex.EncodeToString(hmacRaw(kSigning, sts))
	return "AWS4-HMAC-SHA256 Credential=" + ak + "/" + scope +
		", SignedHeaders=" + join(signed) + ", Signature=" + sig
}

func clientSignWithHeaders(secret, ak, method, uri, amzDate, contentSha string, headers map[string][]string) string {
	dateStamp := amzDate[:8]
	signed := make([]string, 0, len(headers))
	lowered := map[string][]string{}
	for k, v := range headers {
		name := strings.ToLower(k)
		signed = append(signed, name)
		lowered[name] = v
	}
	sort.Strings(signed)

	var canonicalHeaders strings.Builder
	for _, name := range signed {
		vals := lowered[name]
		parts := make([]string, 0, len(vals))
		for _, v := range vals {
			parts = append(parts, collapseSpaces(v))
		}
		canonicalHeaders.WriteString(name)
		canonicalHeaders.WriteByte(':')
		canonicalHeaders.WriteString(strings.Join(parts, ","))
		canonicalHeaders.WriteByte('\n')
	}

	rawPath, rawQuery := uri, ""
	for i := 0; i < len(uri); i++ {
		if uri[i] == '?' {
			rawPath, rawQuery = uri[:i], uri[i+1:]
			break
		}
	}
	cr := method + "\n" + rawPath + "\n" + canonicalQueryString(rawQuery) + "\n" +
		canonicalHeaders.String() + "\n" + join(signed) + "\n" + contentSha
	scope := dateStamp + "/" + region + "/" + service + "/aws4_request"
	sts := "AWS4-HMAC-SHA256\n" + amzDate + "\n" + scope + "\n" + sha256Hex(cr)
	kDate := hmacRaw([]byte("AWS4"+secret), dateStamp)
	kRegion := hmacRaw(kDate, region)
	kService := hmacRaw(kRegion, service)
	kSigning := hmacRaw(kService, "aws4_request")
	sig := hex.EncodeToString(hmacRaw(kSigning, sts))
	return "AWS4-HMAC-SHA256 Credential=" + ak + "/" + scope +
		", SignedHeaders=" + join(signed) + ", Signature=" + sig
}

func hmacRaw(key []byte, msg string) []byte {
	h := hmac.New(sha256.New, key)
	h.Write([]byte(msg))
	return h.Sum(nil)
}
func join(ss []string) string {
	out := ""
	for i, s := range ss {
		if i > 0 {
			out += ";"
		}
		out += s
	}
	return out
}

func setupTestKeys() {
	keysMu.Lock()
	keys = map[string]keyEntry{
		"AKTEST123": {Secret: "secretkey-abc-123"},
	}
	keysMu.Unlock()
	region = "cn-beijing"
	service = "s3"
	maxSkew = 900
	replay = newReplayCache()
}

func doReq(authz, method, uri, host, amzDate, contentSha string) *httptest.ResponseRecorder {
	req := httptest.NewRequest("GET", "/_s3auth", nil)
	req.Header.Set("X-Orig-Method", method)
	req.Header.Set("X-Orig-Uri", uri)
	req.Header.Set("X-Orig-Authorization", authz)
	req.Header.Set("X-Orig-Host", host)
	req.Header.Set("X-Orig-Amz-Date", amzDate)
	req.Header.Set("X-Orig-Content-Sha256", contentSha)
	rw := httptest.NewRecorder()
	handleVerify(rw, req)
	return rw
}

func TestVerify(t *testing.T) {
	region = "cn-beijing"
	service = "s3"
	maxSkew = 900
	replayOn = true
	replay = newReplayCache()
	enabledTrue := true
	enabledFalse := false
	keys = map[string]keyEntry{
		"AKTEST123":  {Secret: "secretkey-abc-123"},
		"AKDISABLED": {Secret: "secretkey-abc-123", Enabled: &enabledFalse},
		"AKEXPIRED":  {Secret: "secretkey-abc-123", Expires: time.Now().UTC().Add(-time.Hour).Format(time.RFC3339)},
		"AKACTIVE":   {Secret: "secretkey-abc-123", Enabled: &enabledTrue, Expires: time.Now().UTC().Add(time.Hour).Format(time.RFC3339)},
	}

	host := "gw.internal:8443"
	amzDate := time.Now().UTC().Format("20060102T150405Z")
	contentSha := "UNSIGNED-PAYLOAD"
	uri := "/demo-bucket/a%20b.txt?x=1&a=2"

	// 1) 正确签名 → 200
	good := clientSign("secretkey-abc-123", "AKTEST123", "PUT", uri, host, amzDate, contentSha)
	if rw := doReq(good, "PUT", uri, host, amzDate, contentSha); rw.Code != 200 {
		t.Fatalf("valid sig expected 200, got %d body=%s", rw.Code, rw.Body.String())
	}
	// 2) 同一签名重放 → 403
	if rw := doReq(good, "PUT", uri, host, amzDate, contentSha); rw.Code != 403 {
		t.Fatalf("replay expected 403, got %d", rw.Code)
	}
	// 3) 错误 SK → 403
	replay = newReplayCache()
	bad := clientSign("WRONG-secret", "AKTEST123", "PUT", uri, host, amzDate, contentSha)
	if rw := doReq(bad, "PUT", uri, host, amzDate, contentSha); rw.Code != 403 {
		t.Fatalf("wrong secret expected 403, got %d", rw.Code)
	}
	// 4) 未知 AK → 403
	replay = newReplayCache()
	unk := clientSign("secretkey-abc-123", "AKUNKNOWN", "PUT", uri, host, amzDate, contentSha)
	if rw := doReq(unk, "PUT", uri, host, amzDate, contentSha); rw.Code != 403 {
		t.Fatalf("unknown ak expected 403, got %d", rw.Code)
	}
	// 5) 时钟偏差过大 → 403
	replay = newReplayCache()
	stale := time.Now().UTC().Add(-30 * time.Minute).Format("20060102T150405Z")
	st := clientSign("secretkey-abc-123", "AKTEST123", "PUT", uri, host, stale, contentSha)
	if rw := doReq(st, "PUT", uri, host, stale, contentSha); rw.Code != 403 {
		t.Fatalf("stale expected 403, got %d", rw.Code)
	}
	// 6) 已禁用的 AK(enabled=false) → 403(快速吊销)
	replay = newReplayCache()
	amzDate6 := time.Now().UTC().Format("20060102T150405Z")
	dis := clientSign("secretkey-abc-123", "AKDISABLED", "PUT", uri, host, amzDate6, contentSha)
	if rw := doReq(dis, "PUT", uri, host, amzDate6, contentSha); rw.Code != 403 {
		t.Fatalf("disabled ak expected 403, got %d", rw.Code)
	}
	// 7) 已过期的 AK(expires 早于当前) → 403
	replay = newReplayCache()
	expd := clientSign("secretkey-abc-123", "AKEXPIRED", "PUT", uri, host, amzDate6, contentSha)
	if rw := doReq(expd, "PUT", uri, host, amzDate6, contentSha); rw.Code != 403 {
		t.Fatalf("expired ak expected 403, got %d", rw.Code)
	}
	// 8) 显式启用且未过期的 AK → 200
	replay = newReplayCache()
	act := clientSign("secretkey-abc-123", "AKACTIVE", "PUT", uri, host, amzDate6, contentSha)
	if rw := doReq(act, "PUT", uri, host, amzDate6, contentSha); rw.Code != 200 {
		t.Fatalf("active ak expected 200, got %d body=%s", rw.Code, rw.Body.String())
	}
}

func TestDynamicSignedHeaders(t *testing.T) {
	setupTestKeys()
	replayOn = false
	host := "gw.internal:8443"
	amzDate := time.Now().UTC().Format("20060102T150405Z")
	contentSha := "UNSIGNED-PAYLOAD"
	uri := "/demo-bucket/a.txt?partNumber=1&uploadId=xyz"
	headers := map[string][]string{
		"Host":                  {host},
		"X-Amz-Content-Sha256":  {contentSha},
		"X-Amz-Date":            {amzDate},
		"Content-Length":        {"11"},
		"X-Amz-Meta-Owner":      {"team a"},
		"X-Amz-Acl":             {"bucket-owner-full-control"},
		"X-Amz-Checksum-Sha256": {"abc123"},
		"X-Amz-Security-Token":  {"token-1"},
		"Range":                 {"bytes=0-10"},
		"If-None-Match":         {`"etag"`},
	}
	authz := clientSignWithHeaders("secretkey-abc-123", "AKTEST123", "PUT", uri, amzDate, contentSha, headers)

	req := httptest.NewRequest(http.MethodGet, "/_s3auth", nil)
	req.Header.Set("X-Orig-Method", "PUT")
	req.Header.Set("X-Orig-Uri", uri)
	req.Header.Set("X-Orig-Authorization", authz)
	req.Header.Set("X-Orig-Host", host)
	req.Header.Set("X-Orig-Amz-Date", amzDate)
	req.Header.Set("X-Orig-Content-Sha256", contentSha)
	req.Header.Set("X-Orig-Content-Length", "11")
	req.Header.Set("X-Orig-Security-Token", "token-1")
	for name, vals := range headers {
		if name == "Host" || name == "X-Amz-Date" || name == "X-Amz-Content-Sha256" ||
			name == "Content-Length" || name == "X-Amz-Security-Token" {
			continue
		}
		for _, v := range vals {
			req.Header.Add(name, v)
		}
	}
	rw := httptest.NewRecorder()
	handleVerify(rw, req)
	if rw.Code != 200 {
		t.Fatalf("dynamic signed headers expected 200, got %d body=%s", rw.Code, rw.Body.String())
	}
}

func TestReplayCacheDefaultsOff(t *testing.T) {
	setupTestKeys()
	replayOn = false
	host := "gw.internal:8443"
	amzDate := time.Now().UTC().Format("20060102T150405Z")
	contentSha := "UNSIGNED-PAYLOAD"
	uri := "/demo-bucket/a.txt"
	authz := clientSign("secretkey-abc-123", "AKTEST123", "GET", uri, host, amzDate, contentSha)
	if rw := doReq(authz, "GET", uri, host, amzDate, contentSha); rw.Code != 200 {
		t.Fatalf("first request expected 200, got %d", rw.Code)
	}
	if rw := doReq(authz, "GET", uri, host, amzDate, contentSha); rw.Code != 200 {
		t.Fatalf("duplicate request should pass when replay cache is off, got %d body=%s", rw.Code, rw.Body.String())
	}
}

// H1 回归：即便全局 replay cache 关闭，写方法(PUT)默认仍强制一次性重放校验，
// 第二次相同签名的 PUT 必须被拒(403)，防止"改体重放"篡改对象。
func TestReplayWritesDefaultOn(t *testing.T) {
	setupTestKeys()
	replayOn = false
	replayWrites = true
	replay = newReplayCache()
	host := "gw.internal:8443"
	amzDate := time.Now().UTC().Format("20060102T150405Z")
	contentSha := "UNSIGNED-PAYLOAD"
	uri := "/demo-bucket/a.txt"
	authz := clientSign("secretkey-abc-123", "AKTEST123", "PUT", uri, host, amzDate, contentSha)
	if rw := doReq(authz, "PUT", uri, host, amzDate, contentSha); rw.Code != 200 {
		t.Fatalf("first PUT expected 200, got %d body=%s", rw.Code, rw.Body.String())
	}
	if rw := doReq(authz, "PUT", uri, host, amzDate, contentSha); rw.Code != 403 {
		t.Fatalf("replayed PUT expected 403 (replayWrites on), got %d", rw.Code)
	}
}

// 关闭 replayWrites 后写方法不再强制查重(留作可关闭的逃生开关)。
func TestReplayWritesCanBeDisabled(t *testing.T) {
	setupTestKeys()
	replayOn = false
	replayWrites = false
	replay = newReplayCache()
	host := "gw.internal:8443"
	amzDate := time.Now().UTC().Format("20060102T150405Z")
	contentSha := "UNSIGNED-PAYLOAD"
	uri := "/demo-bucket/a.txt"
	authz := clientSign("secretkey-abc-123", "AKTEST123", "PUT", uri, host, amzDate, contentSha)
	if rw := doReq(authz, "PUT", uri, host, amzDate, contentSha); rw.Code != 200 {
		t.Fatalf("first PUT expected 200, got %d", rw.Code)
	}
	if rw := doReq(authz, "PUT", uri, host, amzDate, contentSha); rw.Code != 200 {
		t.Fatalf("duplicate PUT should pass when replayWrites off, got %d", rw.Code)
	}
}
