#!/bin/sh

# ================== 日志记录 =================
log_info() {
    local message="$1"
    local max_len=150 # 定义每行的最大长度

    # 如果消息长度超过最大值，则分行记录
    if [ ${#message} -gt $max_len ]; then
        # 使用 grep -o '.\{1,200\}' 将字符串分割成每行最多200个字符
        echo "$message" | grep -o ".\{1,$max_len\}" | while IFS= read -r line; do
            echo "$(date '+%Y-%m-%d %H:%M:%S') - [SCRIPT] - $line"
            logger "[My Crontab Script] $line"
        done
    else
        # 短消息直接记录
        echo "$(date '+%Y-%m-%d %H:%M:%S') - [SCRIPT] - $message"
        logger "[My Crontab Script] $message"
    fi
}
# ==========================================

# 可复用的下载函数：download_file <url> <output_path> [retries]
# - 使用 curl（优先）或 wget 回退
# - 重试次数默认 3 次
# - 成功时通过 log_info 输出：HTTP 状态、字节大小、耗时
# - 失败时重试；全部失败则返回非 0
download_file() {
    url="$1"
    out="$2"
    retries="${3:-3}"

    if [ -z "$url" ] || [ -z "$out" ]; then
        log_info "download_file: usage: download_file <url> <output_path> [retries]"
        return 2
    fi

    attempt=0
    while [ "$attempt" -lt "$retries" ]; do
        attempt=$((attempt + 1))
        log_info "开始下载 (尝试 $attempt/$retries): $url -> $out"
        tmp_out="${out}.part.$$"
        start_ts=$(date +%s.%N 2>/dev/null || date +%s)

        if command -v curl >/dev/null 2>&1; then
            # 使用 curl 获取详细信息
            # -sS: 静默但在出错时显示错误，-L: 跟随重定向，-f: 4xx/5xx 返回非0
            # -w 输出: HTTP_CODE SIZE TIME
            http_info=$(curl -sSL -w "%{http_code} %{size_download} %{time_total}" -o "$tmp_out" "$url" 2>&1)
            ret=$?
            # curl 在成功时将仅输出我们指定的三个字段到 stdout；失败时可能包含错误信息，仍然以非0 退出
            # 取最后三个空格分隔字段作为 http_code size time
            http_code=$(printf "%s" "$http_info" | awk '{print $1}')
            size_download=$(printf "%s" "$http_info" | awk '{print $2}')
            time_total=$(printf "%s" "$http_info" | awk '{print $3}')

        elif command -v wget >/dev/null 2>&1; then
            # wget 回退：保存输出并解析服务器响应以获取 HTTP 状态
            wget_resp=$(wget --server-response --tries=1 -O "$tmp_out" "$url" 2>&1)
            ret=$?
            http_code=$(printf "%s" "$wget_resp" | awk '/^  HTTP\// { code=$2 } END { print code }')
            if [ -f "$tmp_out" ]; then
                size_download=$(wc -c < "$tmp_out" 2>/dev/null || echo 0)
            else
                size_download=0
            fi
            end_ts=$(date +%s.%N 2>/dev/null || date +%s)
            # 计算耗时，使用 awk 做浮点运算（如果 date 不支持 %N，会退到整数）
            time_total=$(awk "BEGIN {print ($end_ts - $start_ts)}")

        else
            log_info "未检测到 curl 或 wget，无法下载: $url"
            return 2
        fi

        if [ "$ret" -eq 0 ]; then
            # 成功，移动临时文件到最终位置
            mv -f "$tmp_out" "$out" 2>/dev/null || cp -f "$tmp_out" "$out" 2>/dev/null
            # 确保数值存在
            size_download=${size_download:-0}
            time_total=${time_total:-0}
            http_code=${http_code:-"-"}
            log_info "下载成功: $url -> $out (HTTP $http_code, ${size_download} bytes, ${time_total}s)"
            return 0
        else
            log_info "下载失败 (尝试 $attempt/$retries): $url (HTTP ${http_code:-"-"})"
            [ -f "$tmp_out" ] && rm -f "$tmp_out"
            if [ "$attempt" -lt "$retries" ]; then
                sleep 1
            fi
        fi
    done

    log_info "下载全部重试失败: $url"
    return 1
}

# 示例：替换原有直接 wget 的调用，调用 download_file
download_file "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/china-list.txt" "/etc/smartdns/download/china-list.txt" 3

# 带日志的重启流程：记录开始、执行重启、记录结果
log_info "等待 3 秒后重启 smartdns..."
sleep 3
log_info "开始重启 smartdns 服务"
if service smartdns restart; then
    log_info "smartdns 重启成功"
else
    rc=$?
    log_info "smartdns 重启失败，退出码: $rc"
fi

# 50 3 */3 * * bash /etc/smartdns/update-geosite.sh
# 33 3 */14 * * reboot