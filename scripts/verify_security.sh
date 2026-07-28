#!/usr/bin/env bash
# ============================================================================
# verify_security.sh -- 验证网关的安全行为是否与承诺一致(可重复执行)。
#
# 与 smoke_test.sh 的分工:
#   smoke_test.sh    验证"能用"  —— PUT/GET/HEAD/DELETE 链路通不通
#   verify_security.sh 验证"可信" —— 未验签是否真被挡在上游之外、重放是否真被拒、
#                                    吊销是否真的秒级生效、真实凭证是否真的不外泄
#
# 需要:.env(含 TEST_VIRT_AK/SK)、curl、python3、docker compose。
# 不打印任何凭证。全程只对 TEST_BUCKET 下的 s3gw-verify/ 前缀读写,结束即清理。
#
# 用法: ./scripts/verify_security.sh
# 退出码: 0 全通过 / 1 有告警 / 2 有失败
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

set -a; [[ -f .env ]] && . ./.env; set +a

: "${TEST_BUCKET:?TEST_BUCKET 未设置(先跑 configure.sh)}"
: "${TEST_VIRT_AK:?TEST_VIRT_AK 未设置}"
: "${TEST_VIRT_SK:?TEST_VIRT_SK 未设置}"
: "${S3_REGION:?S3_REGION 未设置}"

PORT="${GW_LISTEN_PORT:-8443}"
GW="https://127.0.0.1:${PORT}"
SIG="aws:amz:${S3_REGION}:s3"
B="$TEST_BUCKET"
PREFIX="s3gw-verify"
SNI="$(echo "${GW_SERVER_NAMES:-localhost}" | awk '{print $1}')"

PASS=0; WARN=0; FAIL=0
KEY_DISABLED=0
ok(){   printf '  [PASS] %s\n' "$*"; PASS=$((PASS+1)); }
warn(){ printf '  [WARN] %s\n' "$*"; WARN=$((WARN+1)); }
ng(){   printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }
sec(){  printf '\n== %s ==\n' "$*"; }

restore_key() {
  if [[ "$KEY_DISABLED" -eq 1 ]]; then
    if ./scripts/keyctl.sh enable "$TEST_VIRT_AK" >/dev/null 2>&1 \
       && docker compose kill -s HUP authd >/dev/null 2>&1; then
      KEY_DISABLED=0
      printf '\n  [RECOVERY] 已恢复启用测试虚拟密钥\n' >&2
    else
      printf '\n  [RECOVERY][FAIL] 无法恢复测试虚拟密钥,请立即手工执行: ./scripts/keyctl.sh enable %s --reload\n' "$TEST_VIRT_AK" >&2
    fi
  fi
}
trap restore_key EXIT

# 带虚拟签名请求网关,回显 HTTP 码
# 注意:curl 在连接失败时 -w '%{http_code}' 已经会输出 000,
# 再接 "|| echo 000" 会拼成 000000,把判断打乱。这里只取 -w 的输出。
gw_code(){ # gw_code <method> <path+query> [ak] [sk]
  local m="$1" p="$2" ak="${3:-$TEST_VIRT_AK}" sk="${4:-$TEST_VIRT_SK}" c
  c="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 -X "$m" \
    --aws-sigv4 "$SIG" --user "${ak}:${sk}" "${GW}${p}" 2>/dev/null)"
  printf '%s' "${c:-000}"
}

sec "1. 入口与健康检查"
hz="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "${GW}/healthz" 2>/dev/null)"; hz="${hz:-000}"
[[ "$hz" == "200" ]] && ok "本机 /healthz = 200" || ng "本机 /healthz = $hz (期望 200)"

unk="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 -H 'Host: unknown.invalid' "${GW}/${B}/x" 2>/dev/null)"; unk="${unk:-000}"
if [[ "$unk" == "000" || "$unk" == "421" || "$unk" == "444" ]]; then
  ok "未知 Host 被拒绝(连接关闭或 $unk)"
else
  ng "未知 Host 返回 $unk,期望连接被关闭"
fi

sec "2. 虚拟凭证验签"
[[ "$(gw_code GET "/${B}/?list-type=2&max-keys=1")" == "200" ]] \
  && ok "正确虚拟凭证放行" || ng "正确虚拟凭证被拒"

nosig="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "${GW}/${B}/?list-type=2" 2>/dev/null)"; nosig="${nosig:-000}"
[[ "$nosig" == "403" ]] && ok "无签名请求 403" || ng "无签名请求返回 $nosig,期望 403"

[[ "$(gw_code GET "/${B}/?list-type=2" "$TEST_VIRT_AK" "WRONGSECRETWRONGSECRETWRONGSECRET000000")" == "403" ]] \
  && ok "错误虚拟 SK 403" || ng "错误虚拟 SK 未被拒绝"

[[ "$(gw_code GET "/${B}/?list-type=2" "AKDOESNOTEXIST0000" "$TEST_VIRT_SK")" == "403" ]] \
  && ok "未知虚拟 AK 403" || ng "未知虚拟 AK 未被拒绝"

sec "3. 未验签请求不得触达上游"
# 审计日志里 upstream_status 为空,说明请求没有被转发到对象存储
curl -sk -o /dev/null --max-time 15 "${GW}/${B}/?list-type=2" >/dev/null 2>&1
sleep 1
if docker compose exec -T nginx sh -c 'tail -n 5 /var/log/nginx/s3audit.log' 2>/dev/null </dev/null \
   | python3 -c '
import sys,json
bad=0; seen=0
for l in sys.stdin:
    l=l.strip()
    if not l.startswith("{"): continue
    d=json.loads(l)
    if d.get("status")==403:
        seen+=1
        if d.get("upstream_status"): bad+=1
sys.exit(0 if (seen and not bad) else 1)
'; then
  ok "403 请求的 upstream_status 为空(未触达上游)"
else
  warn "未能从审计日志确认(日志可能已轮转)"
fi

sec "4. 桶级操作路由(path-style → virtual-hosted)"
# 回归防线:曾因 nginx map 只匹配 bucket 后带 / 的路径,
# 导致不带尾斜杠的桶级请求被上游当成名为 <bucket> 的对象。
[[ "$(gw_code GET "/${B}?list-type=2&max-keys=1")" == "200" ]] \
  && ok "桶级 ListObjectsV2(不带尾斜杠)" || ng "桶级 ListObjectsV2(不带尾斜杠)失败 —— 检查 nginx map 的单段规则"
[[ "$(gw_code GET "/${B}/?list-type=2&max-keys=1")" == "200" ]] \
  && ok "桶级 ListObjectsV2(带尾斜杠)" || ng "桶级 ListObjectsV2(带尾斜杠)失败"
[[ "$(gw_code HEAD "/${B}")" == "200" ]] \
  && ok "HeadBucket" || ng "HeadBucket 失败 —— 多数 S3 客户端接入时首个调用"

sec "5. 对象读写一致性"
KEY="${PREFIX}/verify-$$.txt"
PAYLOAD="s3gw-verify-$(date -u +%s)"
put="$(printf '%s' "$PAYLOAD" | curl -sk -o /dev/null -w '%{http_code}' --max-time 20 \
  -X PUT --aws-sigv4 "$SIG" --user "${TEST_VIRT_AK}:${TEST_VIRT_SK}" --data-binary @- "${GW}/${B}/${KEY}" 2>/dev/null)"; put="${put:-000}"
[[ "$put" == "200" ]] && ok "PUT 对象" || ng "PUT 对象返回 $put"
got="$(curl -sk --max-time 20 --aws-sigv4 "$SIG" --user "${TEST_VIRT_AK}:${TEST_VIRT_SK}" "${GW}/${B}/${KEY}" 2>/dev/null)"
[[ "$got" == "$PAYLOAD" ]] && ok "GET 内容一致" || ng "GET 内容不一致"

sec "6. 写请求重放防护"
# 手工构造一次 SigV4,把完全相同的 Authorization 连发两次。
# curl 每次都会重新签名,因此必须自行构造才能测出重放。
REPLAY_RC="$(AK="$TEST_VIRT_AK" SK="$TEST_VIRT_SK" REGION="$S3_REGION" \
  BUCKET="$B" SNI="$SNI" PORT="$PORT" PREFIX="$PREFIX" python3 - <<'PY'
import hashlib,hmac,datetime,os,ssl,http.client,sys
ak,sk=os.environ['AK'],os.environ['SK']; region=os.environ['REGION']
bucket=os.environ['BUCKET']; sni=os.environ['SNI']; port=int(os.environ['PORT'])
uri=f"/{bucket}/{os.environ['PREFIX']}/replay-{os.getpid()}.txt"; body=b'replay-probe'
t=datetime.datetime.now(datetime.timezone.utc)
amz=t.strftime('%Y%m%dT%H%M%SZ'); ds=t.strftime('%Y%m%d')
ph=hashlib.sha256(body).hexdigest(); sh='host;x-amz-content-sha256;x-amz-date'
canon=f"PUT\n{uri}\n\nhost:{sni}\nx-amz-content-sha256:{ph}\nx-amz-date:{amz}\n\n{sh}\n{ph}"
scope=f"{ds}/{region}/s3/aws4_request"
sts="AWS4-HMAC-SHA256\n"+amz+"\n"+scope+"\n"+hashlib.sha256(canon.encode()).hexdigest()
def s(k,m): return hmac.new(k,m.encode(),hashlib.sha256).digest()
key=s(s(s(s(('AWS4'+sk).encode(),ds),region),'s3'),'aws4_request')
sig=hmac.new(key,sts.encode(),hashlib.sha256).hexdigest()
hdrs={'Host':sni,'x-amz-content-sha256':ph,'x-amz-date':amz,'Content-Length':str(len(body)),
      'Authorization':f"AWS4-HMAC-SHA256 Credential={ak}/{scope}, SignedHeaders={sh}, Signature={sig}"}
ctx=ssl._create_unverified_context(); codes=[]
for _ in range(2):
    c=http.client.HTTPSConnection('127.0.0.1',port,context=ctx,timeout=20)
    c.request('PUT',uri,body=body,headers=hdrs); codes.append(c.getresponse().status); c.close()
print(f"{codes[0]},{codes[1]}")
sys.exit(0 if (codes[0]==200 and codes[1]==403) else 1)
PY
)"; rc=$?
if [[ $rc -eq 0 ]]; then ok "同一签名重放被拒 (首次/重放 = ${REPLAY_RC})"
else ng "重放防护未生效 (首次/重放 = ${REPLAY_RC:-?})"; fi

sec "7. 虚拟密钥吊销"
if ./scripts/keyctl.sh disable "$TEST_VIRT_AK" --note "verify_security.sh" --reload >/dev/null 2>&1; then
  KEY_DISABLED=1
  sleep 2
  [[ "$(gw_code GET "/${B}/?list-type=2")" == "403" ]] && ok "吊销后立即 403" || ng "吊销后仍可访问"
  if ./scripts/keyctl.sh enable "$TEST_VIRT_AK" >/dev/null 2>&1 \
     && docker compose kill -s HUP authd >/dev/null 2>&1; then
    KEY_DISABLED=0
    sleep 2
    [[ "$(gw_code GET "/${B}/?list-type=2")" == "200" ]] && ok "恢复启用后可访问" || ng "恢复启用后仍被拒"
  else
    ng "恢复启用虚拟密钥失败,退出时将再次尝试"
  fi
else
  warn "keyctl disable 执行失败,跳过吊销验证"
fi

sec "8. 真实凭证隔离"
if [[ -n "${S3_ACCESS_KEY:-}" ]]; then
  logs="$(docker compose logs --no-color --tail 2000 2>/dev/null </dev/null)"
  grep -qF "$S3_ACCESS_KEY" <<<"$logs" && ng "容器日志出现真实 AK" || ok "容器日志无真实 AK"
  [[ -n "${S3_SECRET_KEY:-}" ]] && { grep -qF "$S3_SECRET_KEY" <<<"$logs" && ng "容器日志出现真实 SK" || ok "容器日志无真实 SK"; }
  audit="$(docker compose exec -T nginx sh -c 'tail -n 500 /var/log/nginx/s3audit.log' 2>/dev/null </dev/null)"
  grep -qF "$S3_ACCESS_KEY" <<<"$audit" && ng "审计日志出现真实 AK" || ok "审计日志无真实 AK"
  hdr="$(curl -sk -D- -o /dev/null --max-time 20 --aws-sigv4 "$SIG" --user "${TEST_VIRT_AK}:${TEST_VIRT_SK}" "${GW}/${B}/?list-type=2&max-keys=1" 2>/dev/null)"
  grep -qiF "$S3_ACCESS_KEY" <<<"$hdr" && ng "响应头出现真实 AK" || ok "响应头无真实凭证"
else
  warn "S3_ACCESS_KEY 未在环境中(可能用 imds/sts),跳过凭证泄露检查"
fi

sec "9. 审计可归因"
audit_tail="$(docker compose exec -T nginx sh -c 'tail -n 200 /var/log/nginx/s3audit.log' 2>/dev/null </dev/null)"
if grep -qF "\"access_key\":\"${TEST_VIRT_AK}\"" <<<"$audit_tail"; then
  ok "审计日志按虚拟 AK 归因"
else
  warn "未在审计日志中找到该虚拟 AK 的记录"
fi

sec "10. 运行时收敛"
exposed=""
for c in $(docker compose ps -q 2>/dev/null); do
  service="$(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.service"}}' 2>/dev/null)"
  bindings="$(docker inspect "$c" --format '{{json .HostConfig.PortBindings}}' 2>/dev/null)"
  if [[ -n "$service" && "$bindings" != "null" && "$bindings" != "{}" ]]; then
    exposed="${exposed}${exposed:+,}${service}"
  fi
done
exposed="$(printf '%s' "$exposed" | tr ',' '\n' | sort -u | paste -sd, -)"
if [[ "$exposed" == "nginx" ]]; then ok "仅 nginx 映射宿主端口"
else ng "映射宿主端口的服务: ${exposed:-无} (期望仅 nginx)"; fi

hard_bad=0
for c in $(docker compose ps -q 2>/dev/null); do
  read -r ro caps nnp <<<"$(docker inspect "$c" --format '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}}' 2>/dev/null)"
  [[ "$ro" == "true" && "$caps" == *"ALL"* && "$nnp" == *"no-new-privileges"* ]] || hard_bad=$((hard_bad+1))
done
[[ "$hard_bad" -eq 0 ]] && ok "全部容器 只读根文件系统 + cap_drop:ALL + no-new-privileges" \
  || ng "$hard_bad 个容器未达到加固基线"

sec "清理"
curl -sk -o /dev/null --max-time 20 -X DELETE --aws-sigv4 "$SIG" --user "${TEST_VIRT_AK}:${TEST_VIRT_SK}" "${GW}/${B}/${KEY}" 2>/dev/null
# 重放测试产生的对象按前缀列出后逐个删除
curl -sk --max-time 20 --aws-sigv4 "$SIG" --user "${TEST_VIRT_AK}:${TEST_VIRT_SK}" \
  "${GW}/${B}/?list-type=2&prefix=${PREFIX}/&max-keys=100" 2>/dev/null \
  | grep -o '<Key>[^<]*</Key>' | sed 's/<[^>]*>//g' | while read -r k; do
      [[ -n "$k" ]] && curl -sk -o /dev/null --max-time 20 -X DELETE \
        --aws-sigv4 "$SIG" --user "${TEST_VIRT_AK}:${TEST_VIRT_SK}" "${GW}/${B}/${k}" 2>/dev/null
    done
left="$(curl -sk --max-time 20 --aws-sigv4 "$SIG" --user "${TEST_VIRT_AK}:${TEST_VIRT_SK}" \
  "${GW}/${B}/?list-type=2&prefix=${PREFIX}/&max-keys=100" 2>/dev/null | grep -c '<Key>')"
[[ "$left" -eq 0 ]] && ok "测试对象已清理" || warn "仍有 $left 个测试对象残留(前缀 ${PREFIX}/)"

printf '\n==================== 结果 ====================\n'
printf '  PASS=%s  WARN=%s  FAIL=%s\n' "$PASS" "$WARN" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then echo "  ❌ 有安全行为未达预期"; exit 2; fi
[[ "$WARN" -gt 0 ]] && { echo "  ⚠️  通过,但有告警"; exit 1; }
echo "  ✅ 全部安全行为符合预期"; exit 0
