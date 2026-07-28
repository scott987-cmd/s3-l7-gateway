// creds —— 网关真实 S3 凭证的获取代理（Go 静态二进制版）。
//
// 设计目标（生产标准，零第三方依赖，仅标准库）：
//  1. 云主机不落长期 AK/SK：优先走【实例 IAM 角色 + 元数据服务】(IMDS)，
//     由实例自身身份换取自动轮转的临时凭证。火山 IMDS 支持 v1/v2。
//  2. 非云主机（VMware/物理机）：优先 static 直接使用一把桶 AK/SK；如使用
//     Volcengine，可选走 STS AssumeRole（Volc V4 签名）换临时凭证。
//  3. 三种输出形态，配合 aws-sigv4-proxy 无缝取凭证：
//     (a) 默认：打印 credential_process 规范 JSON
//     (b) --write-shared FILE：原子写入 AWS shared credentials 文件（本地调试/兼容用）
//     (c) --serve：启动 AWS container credentials endpoint，返回带 Expiration 的
//     凭证；compose 中 sigv4-proxy 通过 AWS_CONTAINER_CREDENTIALS_FULL_URI 按
//     provider 语义刷新，避免 shared credentials 被当成静态凭证缓存。
//
// 选源：S3_CREDS_SOURCE = static(默认) | auto | imds | sts
// 其中 imds/sts 当前是 Volcengine 兼容实现；通用 S3 兼容对象存储使用 static。
package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ------------------------------------------------------------------ 常量/配置
const credVersion = 1

// IMDS 默认地址（仅在未显式设置 VOLC_IMDS_HOST 时用作兜底）。
const defaultIMDSHost = "100.96.0.96"

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

var (
	imdsHost     = env("VOLC_IMDS_HOST", defaultIMDSHost)
	imdsRole     = os.Getenv("VOLC_IMDS_ROLE")
	imdsTokenTTL = env("VOLC_IMDS_TOKEN_TTL", "21600")
	imdsTimeout  = 2 * time.Second // 应毫秒级响应；快速失败以便回退

	stsHost   = env("VOLC_STS_HOST", "sts.volcengineapi.com")
	stsRegion = env("VOLC_STS_REGION", "cn-north-1")
	stsSvc    = "sts"
	ltAK      = os.Getenv("VOLC_ACCESS_KEY")
	ltSK      = os.Getenv("VOLC_SECRET_KEY")
	roleTRN   = os.Getenv("VOLC_ROLE_TRN")
	session   = env("VOLC_ROLE_SESSION_NAME", "s3gw")
	duration  = env("VOLC_STS_DURATION", "3600")

	// 显式选源 & 静态兜底（通用 S3 默认 static，避免非 Volcengine 环境无谓探测 IMDS）
	credsSource = strings.ToLower(strings.TrimSpace(env("S3_CREDS_SOURCE", "static")))
	staticAK    = os.Getenv("S3_ACCESS_KEY")
	staticSK    = os.Getenv("S3_SECRET_KEY")
	staticTok   = os.Getenv("S3_SESSION_TOKEN")
	staticRenew = env("S3_STATIC_RENEW", "43200")
)

// Creds 统一凭证结构。
type Creds struct {
	AccessKeyId     string
	SecretAccessKey string
	SessionToken    string
	Expiration      string
}

type credentialCache struct {
	mu            sync.Mutex
	creds         *Creds
	refreshMargin time.Duration
}

func logf(format string, a ...interface{}) {
	fmt.Fprintf(os.Stderr, "[creds] "+format+"\n", a...)
}

func atoiDef(s string, def int) int {
	if n, err := strconv.Atoi(s); err == nil {
		return n
	}
	return def
}

// ============================================================ IMDS(首选)
func imdsToken() string {
	req, err := http.NewRequest(http.MethodPut,
		"http://"+imdsHost+"/latest/api/token", nil)
	if err != nil {
		return ""
	}
	req.Header.Set("X-aws-ec2-metadata-token-ttl-seconds", imdsTokenTTL)
	req.Header.Set("X-ttl", imdsTokenTTL) // 火山兼容头
	cli := &http.Client{Timeout: imdsTimeout}
	resp, err := cli.Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return strings.TrimSpace(string(b))
}

func imdsGet(path, token string) (string, error) {
	req, err := http.NewRequest(http.MethodGet, "http://"+imdsHost+path, nil)
	if err != nil {
		return "", err
	}
	if token != "" {
		req.Header.Set("X-aws-ec2-metadata-token", token)
	}
	cli := &http.Client{Timeout: imdsTimeout}
	resp, err := cli.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	if resp.StatusCode >= 400 {
		return "", fmt.Errorf("imds http %d", resp.StatusCode)
	}
	return string(b), nil
}

func firstNonEmpty(m map[string]interface{}, keys ...string) string {
	for _, k := range keys {
		if v, ok := m[k]; ok {
			if s, ok := v.(string); ok && s != "" {
				return s
			}
		}
	}
	return ""
}

func tryIMDS() *Creds {
	base := "/latest/iam/security_credentials/"
	token := imdsToken() // v2 优先；空则按 v1
	role := imdsRole
	if role == "" {
		listing, err := imdsGet(base, token)
		if err != nil {
			logf("IMDS 不可用(%v)，回退", err)
			return nil
		}
		listing = strings.TrimSpace(listing)
		if listing == "" {
			logf("IMDS 未发现实例角色，回退")
			return nil
		}
		role = strings.TrimSpace(strings.SplitN(listing, "\n", 2)[0])
	}
	body, err := imdsGet(base+url.PathEscape(role), token)
	if err != nil {
		logf("IMDS 不可用(%v)，回退", err)
		return nil
	}
	var data map[string]interface{}
	if err := json.Unmarshal([]byte(body), &data); err != nil {
		logf("IMDS 返回非 JSON，回退")
		return nil
	}
	ak := firstNonEmpty(data, "AccessKeyId", "access_key_id")
	sk := firstNonEmpty(data, "SecretAccessKey", "secret_access_key")
	tok := firstNonEmpty(data, "SessionToken", "Token", "session_token")
	exp := firstNonEmpty(data, "Expiration", "ExpiredTime", "expiration")
	if ak == "" || sk == "" || tok == "" {
		logf("IMDS 返回缺字段，回退")
		return nil
	}
	logf("已通过实例角色 '%s' 获取临时凭证(本机无长期 AK/SK)", role)
	return &Creds{ak, sk, tok, exp}
}

// ============================================================ STS(回退)
func hsum(key []byte, msg string) []byte {
	h := hmac.New(sha256.New, key)
	h.Write([]byte(msg))
	return h.Sum(nil)
}

func sha256hex(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

// volcQuote 复刻 Python urllib.parse.quote(safe="-_.~") 的编码集。
func volcQuote(s string) string {
	const safe = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if strings.IndexByte(safe, c) >= 0 {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

func trySTS() *Creds {
	if ltAK == "" || ltSK == "" || roleTRN == "" {
		return nil
	}
	now := time.Now().UTC()
	amzDate := now.Format("20060102T150405Z")
	dateStamp := now.Format("20060102")

	query := map[string]string{
		"Action":          "AssumeRole",
		"Version":         "2018-01-01",
		"RoleTrn":         roleTRN,
		"RoleSessionName": session,
		"DurationSeconds": duration,
	}
	keys := make([]string, 0, len(query))
	for k := range query {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, volcQuote(k)+"="+volcQuote(query[k]))
	}
	canonicalQS := strings.Join(parts, "&")

	payloadHash := sha256hex("")
	canonicalHeaders := "host:" + stsHost + "\nx-date:" + amzDate + "\n"
	signedHeaders := "host;x-date"
	canonicalRequest := strings.Join([]string{
		"GET", "/", canonicalQS, canonicalHeaders, signedHeaders, payloadHash,
	}, "\n")

	algorithm := "HMAC-SHA256"
	credScope := strings.Join([]string{dateStamp, stsRegion, stsSvc, "request"}, "/")
	stringToSign := strings.Join([]string{
		algorithm, amzDate, credScope, sha256hex(canonicalRequest),
	}, "\n")

	kDate := hsum([]byte(ltSK), dateStamp)
	kRegion := hsum(kDate, stsRegion)
	kService := hsum(kRegion, stsSvc)
	kSigning := hsum(kService, "request")
	signature := hex.EncodeToString(hsum(kSigning, stringToSign))

	authz := fmt.Sprintf("%s Credential=%s/%s, SignedHeaders=%s, Signature=%s",
		algorithm, ltAK, credScope, signedHeaders, signature)

	req, err := http.NewRequest(http.MethodGet,
		"https://"+stsHost+"/?"+canonicalQS, nil)
	if err != nil {
		logf("STS 构造请求失败: %v", err)
		return nil
	}
	req.Host = stsHost
	req.Header.Set("X-Date", amzDate)
	req.Header.Set("Authorization", authz)
	cli := &http.Client{Timeout: 15 * time.Second}
	resp, err := cli.Do(req)
	if err != nil {
		logf("STS 请求失败: %v", err)
		return nil
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		logf("STS HTTP %d: %s", resp.StatusCode, truncate(string(body), 300))
		return nil
	}
	var data struct {
		Result struct {
			Credentials struct {
				AccessKeyId     string
				SecretAccessKey string
				SessionToken    string
				ExpiredTime     string
				Expiration      string
			}
		}
	}
	if err := json.Unmarshal(body, &data); err != nil {
		logf("STS 返回非 JSON: %s", truncate(string(body), 300))
		return nil
	}
	c := data.Result.Credentials
	exp := c.ExpiredTime
	if exp == "" {
		exp = c.Expiration
	}
	if c.AccessKeyId == "" || c.SecretAccessKey == "" || c.SessionToken == "" {
		logf("STS 返回异常: %s", truncate(string(body), 300))
		return nil
	}
	logf("已通过 STS AssumeRole 获取临时凭证(有效期 %ss)", duration)
	return &Creds{c.AccessKeyId, c.SecretAccessKey, c.SessionToken, exp}
}

func truncate(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}

// ============================================================ static / 统一入口
func tryStatic() *Creds {
	if staticAK == "" || staticSK == "" {
		return nil
	}
	logf("使用静态长期 S3 凭证(on-prem 直用，不轮转)")
	return &Creds{staticAK, staticSK, staticTok, ""}
}

func fetchCredentials() *Creds {
	var c *Creds
	switch credsSource {
	case "imds":
		c = tryIMDS()
	case "sts":
		c = trySTS()
	case "static":
		c = tryStatic()
	default: // auto
		if c = tryIMDS(); c == nil {
			if c = trySTS(); c == nil {
				c = tryStatic()
			}
		}
	}
	if c == nil {
		logf("无法获取凭证 source=%s 请检查实例角色/STS 参数/静态 AK/SK 配置", credsSource)
		os.Exit(1)
	}
	return c
}

func parseExpiry(iso string) time.Time {
	if iso != "" {
		layouts := []string{
			"2006-01-02T15:04:05Z",
			"2006-01-02T15:04:05Z07:00",
			"2006-01-02T15:04:05.000Z",
		}
		for _, l := range layouts {
			if t, err := time.Parse(l, iso); err == nil {
				return t.UTC()
			}
		}
	}
	return time.Now().UTC().Add(time.Duration(atoiDef(duration, 3600)) * time.Second)
}

func (c *credentialCache) get() *Creds {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.creds != nil {
		if c.creds.Expiration == "" {
			return c.creds
		}
		if time.Until(parseExpiry(c.creds.Expiration)) > c.refreshMargin {
			return c.creds
		}
	}
	c.creds = fetchCredentials()
	return c.creds
}

func containerCredsPayload(c *Creds) map[string]interface{} {
	out := map[string]interface{}{
		"AccessKeyId":     c.AccessKeyId,
		"SecretAccessKey": c.SecretAccessKey,
		"Token":           c.SessionToken,
	}
	if c.Expiration != "" {
		out["Expiration"] = c.Expiration
	} else {
		out["Expiration"] = time.Now().UTC().Add(time.Duration(atoiDef(staticRenew, 43200)) * time.Second).Format(time.RFC3339)
	}
	return out
}

func writeShared(path, profile string, c *Creds) error {
	abs, err := filepath.Abs(path)
	if err != nil {
		return err
	}
	dir := filepath.Dir(abs)
	if dir != "" {
		if _, err := os.Stat(dir); os.IsNotExist(err) {
			if err := os.MkdirAll(dir, 0o700); err != nil {
				return err
			}
		}
	}
	body := fmt.Sprintf("[%s]\naws_access_key_id = %s\naws_secret_access_key = %s\n",
		profile, c.AccessKeyId, c.SecretAccessKey)
	if c.SessionToken != "" {
		body += "aws_session_token = " + c.SessionToken + "\n"
	}
	tmp := abs + ".tmp"
	if err := os.WriteFile(tmp, []byte(body), 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, abs); err != nil {
		return err
	}
	logf("已写入 shared credentials: %s (profile=%s)", path, profile)
	return nil
}

func writeReady(path string) {
	if path == "" {
		return
	}
	if err := os.WriteFile(path, []byte("ok\n"), 0o644); err != nil {
		logf("写 ready 文件失败: %v", err)
	}
}

func runHealthCheck(listen string) {
	_, portStr, err := net.SplitHostPort(listen)
	if err != nil {
		portStr = "8181"
	}
	target := "http://127.0.0.1:" + portStr + "/healthz"
	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get(target)
	if err != nil {
		logf("healthcheck failed: %v", err)
		os.Exit(1)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode != http.StatusOK {
		logf("healthcheck status=%d", resp.StatusCode)
		os.Exit(1)
	}
	os.Exit(0)
}

func emitProcessJSON(c *Creds) {
	out := map[string]interface{}{
		"Version":         credVersion,
		"AccessKeyId":     c.AccessKeyId,
		"SecretAccessKey": c.SecretAccessKey,
		"SessionToken":    c.SessionToken,
	}
	if c.Expiration != "" {
		out["Expiration"] = c.Expiration
	}
	b, _ := json.Marshal(out)
	os.Stdout.Write(append(b, '\n'))
}

func runLoop(path, profile string, refreshMargin int) {
	for {
		c := fetchCredentials()
		if err := writeShared(path, profile, c); err != nil {
			logf("写共享凭证失败: %v", err)
			os.Exit(1)
		}
		var sleep time.Duration
		if c.Expiration != "" {
			exp := parseExpiry(c.Expiration)
			s := time.Until(exp) - time.Duration(refreshMargin)*time.Second
			if s < 60*time.Second {
				s = 60 * time.Second
			}
			sleep = s
		} else {
			s := atoiDef(staticRenew, 43200)
			if s < 60 {
				s = 60
			}
			sleep = time.Duration(s) * time.Second
		}
		expStr := c.Expiration
		if expStr == "" {
			expStr = "未知"
		}
		logf("下次续期 %d 秒后(到期时间 %s)", int(sleep.Seconds()), expStr)
		time.Sleep(sleep)
	}
}

func runServer(listen, readyPath string, refreshMargin int) {
	cache := &credentialCache{refreshMargin: time.Duration(refreshMargin) * time.Second}
	cache.get()
	writeReady(readyPath)

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("/credentials", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		c := cache.get()
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(containerCredsPayload(c)); err != nil {
			logf("编码凭证响应失败: %v", err)
		}
	})

	srv := &http.Server{
		Addr:              listen,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	host, _, err := net.SplitHostPort(listen)
	if err == nil && host != "127.0.0.1" && host != "localhost" {
		logf("警告: 凭证端点监听在 %s，生产建议仅绑定 127.0.0.1", listen)
	}
	logf("container credentials endpoint listening on %s", listen)
	if err := srv.ListenAndServe(); err != nil {
		logf("凭证端点退出: %v", err)
		os.Exit(1)
	}
}

func main() {
	loop := flag.Bool("loop", false, "常驻，到期前自动续期并重写 shared credentials 文件")
	writeSharedPath := flag.String("write-shared", "", "将凭证以 AWS shared credentials 格式原子写入该文件")
	profile := flag.String("profile", "default", "shared credentials 段名，默认 default")
	refreshMargin := flag.Int("refresh-margin", 300, "到期前多少秒续期，默认 300")
	serve := flag.Bool("serve", false, "启动 AWS container credentials HTTP endpoint")
	listen := flag.String("listen", "127.0.0.1:8181", "凭证 HTTP endpoint 监听地址")
	readyPath := flag.String("ready-file", "", "首次取到凭证后写入该 ready 文件")
	health := flag.Bool("health", false, "检查本机凭证 HTTP endpoint 健康状态")
	flag.Parse()

	if *health {
		runHealthCheck(*listen)
		return
	}

	if *serve {
		runServer(*listen, *readyPath, *refreshMargin)
		return
	}

	if *loop {
		if *writeSharedPath == "" {
			logf("--loop 需配合 --write-shared FILE")
			os.Exit(1)
		}
		runLoop(*writeSharedPath, *profile, *refreshMargin)
		return
	}

	c := fetchCredentials()
	if *writeSharedPath != "" {
		if err := writeShared(*writeSharedPath, *profile, c); err != nil {
			logf("写共享凭证失败: %v", err)
			os.Exit(1)
		}
	} else {
		emitProcessJSON(c)
	}
}
