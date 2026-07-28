// authd —— 零依赖 SigV4 验签服务（配合 nginx auth_request）。Go 版。
//
// 作用：aws-sigv4-proxy 只"重签"不"验签"。本服务补上"验签"这一环：
//
//	客户端用【只在网关生效的虚拟 AK/SK】按标准 S3 SigV4 签名 → nginx 把请求头
//	经 auth_request 子请求转发到本服务 → 本服务用同一把虚拟 SK 重算签名比对 →
//	通过(200)才放行给 sigv4-proxy 用【真实 S3 凭证】重签转发。
//
// 客户端全程是标准 S3 客户端(boto3/aws-cli)，零代码改造：只配 endpoint + 一套
// 虚拟 AK/SK + path-style 即可。
//
// 为什么不破坏大对象流式：SigV4 的 canonical request 里，payload 只以
// x-amz-content-sha256 头的【值】参与（该头本身在签名覆盖范围内）。所以只凭请求头
// 即可验签，auth_request 子请求无需请求体，nginx 侧 proxy_request_buffering off 的
// 流式转发保持不变。客户端对大对象常发 UNSIGNED-PAYLOAD，本服务原样采用该值。
//
// 编译为静态二进制（CGO_ENABLED=0），无运行时依赖、无解释器、无 pip 解依赖。
//
// 环境变量：
//
//	AUTHD_LISTEN        默认 0.0.0.0:8081
//	AUTHD_KEYS_FILE     虚拟 AK/SK 库(JSON: {"<access_key>":"<secret_key>"})，默认 ./keys.json
//	AUTHD_REGION        期望的签名 region，默认 cn-beijing（须与客户端签名 region 一致）
//	AUTHD_SERVICE       期望的 service，默认 s3
//	AUTHD_MAX_SKEW      允许的时钟偏差秒数(防重放)，默认 900
//	AUTHD_REPLAY_CACHE  是否开启一次性签名重放缓存，默认 0(关闭)；1 开启
//	AUTHD_REPLAY_WRITES 对写方法(PUT/POST/DELETE/PATCH)强制一次性重放校验，默认 1(开启)；0 关闭
package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

var (
	listen   = env("AUTHD_LISTEN", "0.0.0.0:8081")
	keysFile = env("AUTHD_KEYS_FILE", "./keys.json")
	region   = env("AUTHD_REGION", "cn-beijing")
	service  = env("AUTHD_SERVICE", "s3")
	// 时钟偏差窗口收敛到 300s(原 900s)：SigV4 对时钟敏感，300s 已足够容忍常见 NTP 漂移，
	// 同时把"合法签名可被重放的时间窗"从 15 分钟压到 5 分钟。
	maxSkew = envInt("AUTHD_MAX_SKEW", 300)
	// replayOn: 对【所有方法】开启一次性签名重放缓存(默认关，避免误拒读类重试)。
	replayOn = env("AUTHD_REPLAY_CACHE", "0") == "1"
	// replayWrites: 仅对【写方法】(PUT/POST/DELETE/PATCH)强制一次性重放校验，默认【开启】。
	//   动因：authd 只验请求头、不重算 body 哈希，且上游用 UNSIGNED-PAYLOAD 重签，
	//   写请求的合法签名一旦被重放即可篡改/覆盖对象。写类天然幂等重试少，强制查重风险低。
	replayWrites = env("AUTHD_REPLAY_WRITES", "1") == "1"
)

func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func envInt(k string, d int) int {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return d
}

// ---- keys 库：进程启动加载 + SIGHUP 热加载；用 RWMutex 保护 ----
//
// keyEntry —— 单条虚拟密钥的完整元数据。keys.json 兼容两种写法：
//
//  1. 传统扁平格式:  {"<AK>": "<SK>"}                     —— 视为启用、永不过期
//  2. 富元数据格式:  {"<AK>": {"secret":"<SK>","owner":"team-x",
//     "enabled":true,"expires":"2026-12-31T23:59:59Z","note":"..."}}
//
// 快速吊销一把虚拟 AK/SK：把该 AK 的 enabled 置 false(或把 expires 设为已过去的时刻)，
// 再对 authd 发 SIGHUP 热加载即可——无需重启、秒级生效，且保留审计痕迹(不必删除条目)。
type keyEntry struct {
	Secret  string `json:"secret"`
	Owner   string `json:"owner,omitempty"`
	Enabled *bool  `json:"enabled,omitempty"`
	Expires string `json:"expires,omitempty"`
	Note    string `json:"note,omitempty"`
}

var (
	keysMu sync.RWMutex
	keys   = map[string]keyEntry{}
)

func loadKeys() int {
	b, err := os.ReadFile(keysFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[authd] 无法读取 keys 文件 %s: %v\n", keysFile, err)
		return 0
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(b, &raw); err != nil {
		fmt.Fprintf(os.Stderr, "[authd] keys 文件 JSON 解析失败 %s: %v\n", keysFile, err)
		return 0
	}
	parsed := make(map[string]keyEntry, len(raw))
	for ak, rv := range raw {
		// 先按字符串(传统扁平格式)尝试
		var sk string
		if err := json.Unmarshal(rv, &sk); err == nil {
			parsed[ak] = keyEntry{Secret: sk}
			continue
		}
		// 再按富元数据结构尝试
		var e keyEntry
		if err := json.Unmarshal(rv, &e); err == nil && e.Secret != "" {
			parsed[ak] = e
			continue
		}
		fmt.Fprintf(os.Stderr, "[authd] 跳过无法解析的密钥条目: %s\n", ak)
	}
	keysMu.Lock()
	keys = parsed
	keysMu.Unlock()
	return len(parsed)
}

// lookupKey 返回可用密钥的 secret。密钥被禁用(enabled=false)或已过期(expires 早于当前)
// 时返回 ok=false —— 等价于"已吊销"，authd 立即拒绝该虚拟 AK 的所有请求。
func lookupKey(ak string) (string, bool) {
	keysMu.RLock()
	e, ok := keys[ak]
	keysMu.RUnlock()
	if !ok {
		return "", false
	}
	if e.Enabled != nil && !*e.Enabled {
		return "", false
	}
	if e.Expires != "" {
		if exp, err := time.Parse(time.RFC3339, e.Expires); err == nil {
			if time.Now().After(exp) {
				return "", false
			}
		}
	}
	return e.Secret, true
}

// ---- 重放缓存：记录已用过的 (signature) 到其过期时刻；带惰性清理 ----
type replayCache struct {
	mu   sync.Mutex
	seen map[string]time.Time
}

func newReplayCache() *replayCache { return &replayCache{seen: map[string]time.Time{}} }

// checkAndAdd 返回 true 表示是新签名（放行）；false 表示重复（拒绝）。
func (c *replayCache) checkAndAdd(sig string, exp time.Time) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := time.Now()
	// 惰性清理
	if len(c.seen) > 4096 {
		for k, t := range c.seen {
			if now.After(t) {
				delete(c.seen, k)
			}
		}
	}
	if t, ok := c.seen[sig]; ok && now.Before(t) {
		return false
	}
	c.seen[sig] = exp
	return true
}

var replay = newReplayCache()

// ---- SigV4 原语 ----
func hmacSHA256(key []byte, msg string) []byte {
	h := hmac.New(sha256.New, key)
	h.Write([]byte(msg))
	return h.Sum(nil)
}

func sha256Hex(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

func deriveKey(secret, dateStamp string) []byte {
	kDate := hmacSHA256([]byte("AWS4"+secret), dateStamp)
	kRegion := hmacSHA256(kDate, region)
	kService := hmacSHA256(kRegion, service)
	return hmacSHA256(kService, "aws4_request")
}

type authInfo struct {
	accessKey    string
	dateStamp    string
	region       string
	service      string
	signedHeader []string
	signature    string
}

// parseAuthorization 解析 `AWS4-HMAC-SHA256 Credential=.., SignedHeaders=.., Signature=..`
func parseAuthorization(authz string) *authInfo {
	const prefix = "AWS4-HMAC-SHA256"
	if !strings.HasPrefix(authz, prefix) {
		return nil
	}
	body := strings.TrimSpace(authz[len(prefix):])
	parts := map[string]string{}
	for _, seg := range strings.Split(body, ",") {
		seg = strings.TrimSpace(seg)
		if i := strings.Index(seg, "="); i >= 0 {
			parts[strings.TrimSpace(seg[:i])] = strings.TrimSpace(seg[i+1:])
		}
	}
	cred := parts["Credential"]
	sh := parts["SignedHeaders"]
	sig := parts["Signature"]
	if cred == "" || sh == "" || sig == "" {
		return nil
	}
	cp := strings.Split(cred, "/")
	if len(cp) != 5 || cp[4] != "aws4_request" {
		return nil
	}
	return &authInfo{
		accessKey:    cp[0],
		dateStamp:    cp[1],
		region:       cp[2],
		service:      cp[3],
		signedHeader: strings.Split(sh, ";"),
		signature:    sig,
	}
}

// canonicalQueryString 把原始 query 重建为 SigV4 规范格式
// (key/value 各自先 unquote 再 quote，按 key 排序)。
func canonicalQueryString(rawQuery string) string {
	if rawQuery == "" {
		return ""
	}
	type kv struct{ k, v string }
	var pairs []kv
	for _, item := range strings.Split(rawQuery, "&") {
		if item == "" {
			continue
		}
		var k, v string
		if i := strings.Index(item, "="); i >= 0 {
			k, v = item[:i], item[i+1:]
		} else {
			k, v = item, ""
		}
		k = awsURIEncode(unquote(k))
		v = awsURIEncode(unquote(v))
		pairs = append(pairs, kv{k, v})
	}
	sort.Slice(pairs, func(i, j int) bool {
		if pairs[i].k == pairs[j].k {
			return pairs[i].v < pairs[j].v
		}
		return pairs[i].k < pairs[j].k
	})
	var sb strings.Builder
	for i, p := range pairs {
		if i > 0 {
			sb.WriteByte('&')
		}
		sb.WriteString(p.k)
		sb.WriteByte('=')
		sb.WriteString(p.v)
	}
	return sb.String()
}

func unquote(s string) string {
	if u, err := url.QueryUnescape(s); err == nil {
		return u
	}
	return s
}

// awsURIEncode 按 SigV4 规则编码：unreserved 字符 A-Za-z0-9-_.~ 不编码，其余 %XX 大写。
func awsURIEncode(s string) string {
	const upperhex = "0123456789ABCDEF"
	var sb strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
			c == '-' || c == '_' || c == '.' || c == '~' {
			sb.WriteByte(c)
		} else {
			sb.WriteByte('%')
			sb.WriteByte(upperhex[c>>4])
			sb.WriteByte(upperhex[c&0xf])
		}
	}
	return sb.String()
}

func collapseSpaces(v string) string {
	return strings.Join(strings.Fields(v), " ")
}

func headerValues(h http.Header, name string) ([]string, bool) {
	canonical := http.CanonicalHeaderKey(name)
	if vals, ok := h[canonical]; ok {
		return vals, true
	}
	return nil, false
}

func originalHeaderValues(h http.Header, name string) ([]string, bool) {
	switch name {
	case "host":
		if vals, ok := headerValues(h, "X-Orig-Host"); ok {
			return vals, true
		}
		return headerValues(h, "Host")
	case "authorization":
		if vals, ok := headerValues(h, "X-Orig-Authorization"); ok {
			return vals, true
		}
		return headerValues(h, "Authorization")
	case "content-length":
		if vals, ok := headerValues(h, "X-Orig-Content-Length"); ok {
			return vals, true
		}
		return headerValues(h, "Content-Length")
	case "content-type":
		if vals, ok := headerValues(h, "X-Orig-Content-Type"); ok {
			return vals, true
		}
		return headerValues(h, "Content-Type")
	case "content-md5":
		if vals, ok := headerValues(h, "X-Orig-Content-Md5"); ok {
			return vals, true
		}
		return headerValues(h, "Content-Md5")
	case "x-amz-date":
		if vals, ok := headerValues(h, "X-Orig-Amz-Date"); ok {
			return vals, true
		}
		return headerValues(h, "X-Amz-Date")
	case "x-amz-content-sha256":
		if vals, ok := headerValues(h, "X-Orig-Content-Sha256"); ok {
			return vals, true
		}
		return headerValues(h, "X-Amz-Content-Sha256")
	case "x-amz-security-token":
		if vals, ok := headerValues(h, "X-Orig-Security-Token"); ok {
			return vals, true
		}
		if vals, ok := headerValues(h, "X-Orig-Amz-Security-Token"); ok {
			return vals, true
		}
		return headerValues(h, "X-Amz-Security-Token")
	default:
		return headerValues(h, name)
	}
}

func canonicalHeaderValue(vals []string) string {
	parts := make([]string, 0, len(vals))
	for _, v := range vals {
		parts = append(parts, collapseSpaces(v))
	}
	return strings.Join(parts, ",")
}

func originalHeaderValue(h http.Header, name string) (string, bool) {
	vals, ok := originalHeaderValues(h, name)
	if !ok {
		return "", false
	}
	return canonicalHeaderValue(vals), true
}

// isWriteMethod 判断是否为会改变对象状态的写方法。此类请求即便"只验头不验体",
// 一旦合法签名被重放即可篡改/覆盖对象，故默认强制一次性重放校验(见 replayWrites)。
func isWriteMethod(m string) bool {
	switch strings.ToUpper(m) {
	case http.MethodPut, http.MethodPost, http.MethodDelete, http.MethodPatch:
		return true
	default:
		return false
	}
}

func deny(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(code)
	_, _ = w.Write([]byte(msg + "\n"))
}

func allow(w http.ResponseWriter, accessKey string) {
	w.Header().Set("X-Access-Key", accessKey)
	w.WriteHeader(http.StatusOK)
}

// handleHealth —— 无鉴权健康探针，仅表明进程存活/已就绪。
func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok\n"))
}

// runHealthCheck —— 供容器 healthcheck 以 exec 形式调用(`/authd -health`)。
// scratch 镜像无 shell/wget，故把探针内建进二进制：向本机 /healthz 发一次 GET，
// 200 -> 退出 0，否则退出 1。不监听端口，仅作为客户端连接。
func runHealthCheck() {
	_, portStr, err := net.SplitHostPort(listen)
	if err != nil {
		portStr = "8081"
	}
	target := "http://127.0.0.1:" + portStr + "/healthz"
	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get(target)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[authd -health] %v\n", err)
		os.Exit(1)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode != http.StatusOK {
		fmt.Fprintf(os.Stderr, "[authd -health] status=%d\n", resp.StatusCode)
		os.Exit(1)
	}
	os.Exit(0)
}

func handleVerify(w http.ResponseWriter, r *http.Request) {
	h := r.Header
	method := h.Get("X-Orig-Method")
	origURI := h.Get("X-Orig-Uri")
	authz := h.Get("X-Orig-Authorization")
	if authz == "" {
		authz = h.Get("Authorization")
	}
	if method == "" || origURI == "" {
		deny(w, 403, "missing original request metadata")
		return
	}

	parsed := parseAuthorization(authz)
	if parsed == nil {
		deny(w, 403, "malformed or missing SigV4 Authorization")
		return
	}
	if parsed.region != region || parsed.service != service {
		deny(w, 403, "credential scope mismatch (region/service)")
		return
	}

	secret, ok := lookupKey(parsed.accessKey)
	if !ok {
		deny(w, 403, "unknown access key")
		return
	}

	amzDate, ok := originalHeaderValue(h, "x-amz-date")
	if !ok || amzDate == "" {
		deny(w, 403, "missing x-amz-date")
		return
	}
	t, err := time.Parse("20060102T150405Z", amzDate)
	if err != nil {
		deny(w, 403, "bad x-amz-date format")
		return
	}
	skew := time.Since(t)
	if skew < 0 {
		skew = -skew
	}
	if skew > time.Duration(maxSkew)*time.Second {
		deny(w, 403, "request time skew too large")
		return
	}
	// x-amz-date 的日期必须与 Credential scope 的 date 一致，防止跨日拼接
	if !strings.HasPrefix(amzDate, parsed.dateStamp) {
		deny(w, 403, "x-amz-date does not match credential date")
		return
	}

	// 拆 path / query
	rawPath, rawQuery := origURI, ""
	if i := strings.Index(origURI, "?"); i >= 0 {
		rawPath, rawQuery = origURI[:i], origURI[i+1:]
	}
	canonicalURI := rawPath
	if canonicalURI == "" {
		canonicalURI = "/"
	}
	canonicalQS := canonicalQueryString(rawQuery)

	// SignedHeaders 必须小写、去空、且严格升序（SigV4 规范要求已排序）
	signed := make([]string, 0, len(parsed.signedHeader))
	for _, s := range parsed.signedHeader {
		signed = append(signed, strings.ToLower(strings.TrimSpace(s)))
	}
	for i := 1; i < len(signed); i++ {
		if signed[i-1] >= signed[i] {
			deny(w, 403, "signed headers not sorted/unique")
			return
		}
	}
	// host 必须在签名覆盖内，避免攻击者改写目标
	hostSigned := false
	var canonicalHeaders strings.Builder
	for _, name := range signed {
		val, exists := originalHeaderValue(h, name)
		if !exists {
			deny(w, 403, "signed header not forwarded by gateway: "+name)
			return
		}
		if name == "host" {
			hostSigned = true
		}
		canonicalHeaders.WriteString(name)
		canonicalHeaders.WriteByte(':')
		canonicalHeaders.WriteString(val)
		canonicalHeaders.WriteByte('\n')
	}
	if !hostSigned {
		deny(w, 403, "host header must be signed")
		return
	}

	payloadHash, ok := originalHeaderValue(h, "x-amz-content-sha256")
	if !ok || payloadHash == "" {
		payloadHash = "UNSIGNED-PAYLOAD"
	}

	canonicalRequest := strings.Join([]string{
		method,
		canonicalURI,
		canonicalQS,
		canonicalHeaders.String(),
		strings.Join(signed, ";"),
		payloadHash,
	}, "\n")

	scope := strings.Join([]string{parsed.dateStamp, region, service, "aws4_request"}, "/")
	stringToSign := strings.Join([]string{
		"AWS4-HMAC-SHA256",
		amzDate,
		scope,
		sha256Hex(canonicalRequest),
	}, "\n")

	signingKey := deriveKey(secret, parsed.dateStamp)
	expected := hex.EncodeToString(hmacSHA256(signingKey, stringToSign))

	if !hmac.Equal([]byte(expected), []byte(parsed.signature)) {
		deny(w, 403, "signature mismatch")
		return
	}

	// 通过验签后做一次性重放校验：同一签名在 skew 窗口内只放行一次。
	//   - replayOn(AUTHD_REPLAY_CACHE=1)：对所有方法开启；
	//   - replayWrites(AUTHD_REPLAY_WRITES=1，默认)：仅对写方法开启。
	// 读方法(GET/HEAD)默认不查重，避免误拒 SDK 重试与重复读取。
	if replayOn || (replayWrites && isWriteMethod(method)) {
		exp := t.Add(time.Duration(maxSkew) * time.Second)
		if !replay.checkAndAdd(parsed.signature, exp) {
			deny(w, 403, "replayed signature")
			return
		}
	}

	allow(w, parsed.accessKey)
}

func main() {
	// 容器 healthcheck 探针模式：`/authd -health`（不启动服务）。
	if len(os.Args) > 1 && (os.Args[1] == "-health" || os.Args[1] == "--health") {
		runHealthCheck()
		return
	}

	n := loadKeys()
	if n == 0 {
		fmt.Fprintf(os.Stderr, "[authd] 警告：keys 库为空，所有请求都会被拒绝。请生成 %s\n", keysFile)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", handleHealth)
	mux.HandleFunc("/", handleVerify)

	// SIGHUP 热重载 keys 库：无需重启即可吊销/新增虚拟密钥。
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGHUP)
	go func() {
		for range sigCh {
			cnt := loadKeys()
			fmt.Fprintf(os.Stderr, "[authd] SIGHUP 已重载 keys：%d 条\n", cnt)
		}
	}()

	host, portStr, err := net.SplitHostPort(listen)
	if err != nil {
		host, portStr = "0.0.0.0", "8081"
	}
	addr := net.JoinHostPort(host, portStr)

	srv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    64 << 10,
	}
	fmt.Fprintf(os.Stderr, "[authd] listening on %s  region=%s service=%s keys=%d maxSkew=%ds replay=%v replayWrites=%v\n",
		addr, region, service, n, maxSkew, replayOn, replayWrites)
	if err := srv.ListenAndServe(); err != nil {
		fmt.Fprintf(os.Stderr, "[authd] server exited: %v\n", err)
		os.Exit(1)
	}
}
