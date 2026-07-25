#!/bin/bash
set -e

# 颜色输出函数
log_info() {
    echo "ℹ️  $1"
}

log_success() {
    echo "✅ $1"
}

log_error() {
    echo "❌ $1"
    exit 1
}

log_warning() {
    echo "⚠️  $1"
}

log_step() {
    echo "🔄 $1"
}

# 检查必需的环境变量
check_required_env() {
    log_step "检查环境变量..."

    if [ -z "$VELOCITY_JAR_URL" ]; then
        log_error "VELOCITY_JAR_URL 环境变量未设置"
    fi

    if [ -z "$VELOCITY_CONFIG_URL" ]; then
        log_error "VELOCITY_CONFIG_URL 环境变量未设置"
    fi

    if [ -z "$FORWARDING_SECRET_URL" ]; then
        log_error "FORWARDING_SECRET_URL 环境变量未设置"
    fi

    if [ -z "$PLUGINS_ZIP_URL" ]; then
        log_warning "PLUGINS_ZIP_URL 环境变量未设置，将跳过插件下载"
    fi

    log_success "环境变量检查完成"
}

# 下载文件的函数
download_file() {
    local url=$1
    local output_file=$2
    local description=$3

    log_step "正在下载 $description..."
    if curl -sSL -f -o "$output_file" "$url"; then
        log_success "$description 下载完成 ($(ls -lh "$output_file" | awk '{print $5}'))"
    else
        log_error "下载 $description 失败: $url"
    fi
}

# 下载并解压插件包
#
# 插件目录是持久卷。历史上这里直接 unzip -o 叠加，旧版本 jar 永远不会被清掉，
# 于是同一个插件会有多个版本共存 —— Velocity 遇到同 id 多版本不会报错，而是
# 按目录扫描顺序静默挑一个（实测挑中的常常是旧版），导致插件更新看似成功、
# 实际从未生效。因此默认让 plugins.zip 成为唯一事实来源：解压前把根层已有的
# jar 归档到 .superseded/，解压后根层就只剩 zip 里的那一份。
# 插件的配置目录（luckperms/ 等）和它们的 libs/ 依赖缓存不受影响。
# 需要保留旧行为可设 PLUGINS_PRUNE=false。
download_and_extract_plugins() {
    local plugins_zip="/tmp/plugins.zip"
    local plugins_dir="/app/plugins"
    local archive_dir="${plugins_dir}/.superseded"

    log_step "正在下载插件压缩包..."
    if curl -sSL -f -o "$plugins_zip" "$PLUGINS_ZIP_URL"; then
        log_success "插件压缩包下载完成 ($(ls -lh "$plugins_zip" | awk '{print $5}'))"

        mkdir -p "$plugins_dir"

        if [ "${PLUGINS_PRUNE:-true}" = "true" ]; then
            local stale=0
            for jar in "$plugins_dir"/*.jar; do
                [ -e "$jar" ] || break
                mkdir -p "$archive_dir"
                mv -f "$jar" "$archive_dir"/ && stale=$((stale + 1))
            done
            if [ "$stale" -gt 0 ]; then
                log_info "已归档 $stale 个旧插件 jar 到 ${archive_dir}/（plugins.zip 为唯一来源）"
            fi
        else
            log_warning "PLUGINS_PRUNE=false，保留既有 jar（同插件多版本会被 Velocity 随机选取）"
        fi

        log_step "解压插件包到 ${plugins_dir}/..."
        if unzip -o "$plugins_zip" -d "${plugins_dir}/"; then
            log_success "插件解压完成"

            # 显示解压后的插件列表（只列根层，libs/ 里的是依赖缓存不是插件）
            log_info "已安装的插件："
            find "$plugins_dir" -maxdepth 1 -name "*.jar" -exec basename {} \; | sort
        else
            log_error "插件解压失败"
        fi

        # 清理临时文件
        rm -f "$plugins_zip"
    else
        log_error "下载插件压缩包失败: $PLUGINS_ZIP_URL"
    fi
}

# 验证下载的文件
verify_files() {
    log_step "验证下载的文件..."

    if [ ! -f "/app/velocity.jar" ]; then
        log_error "velocity.jar 文件不存在"
    fi

    if [ ! -f "/app/velocity.toml" ]; then
        log_error "velocity.toml 文件不存在"
    fi

    if [ ! -f "/app/forwarding.secret" ]; then
        log_error "forwarding.secret 文件不存在"
    fi

    # 检查JAR文件是否为有效的ZIP文件
    if ! unzip -t "/app/velocity.jar" >/dev/null 2>&1; then
        log_error "velocity.jar 文件损坏或格式无效"
    fi

    # 检查转发密钥文件是否非空
    if [ ! -s "/app/forwarding.secret" ]; then
        log_error "forwarding.secret 文件为空"
    fi

    # 提前比对 jar 的 class file 版本与本机 JRE，避免只留下一句
    # UnsupportedClassVersionError 然后陷入重启循环
    check_jar_class_version

    log_success "文件验证通过"
}

# 读取 velocity.jar 主类的 class file 版本，和当前 JRE 支持的最高版本比对。
# class file 版本 = Java 主版本 + 44（Java 21 -> 65，Java 25 -> 69）。
check_jar_class_version() {
    local main_class="com/velocitypowered/proxy/Velocity.class"
    local required jre_major jre_supported

    required=$(unzip -p /app/velocity.jar "$main_class" 2>/dev/null \
        | od -An -tu1 -j6 -N2 2>/dev/null \
        | awk '{print $1 * 256 + $2}')

    if [ -z "$required" ]; then
        log_warning "无法读取 velocity.jar 的 class file 版本，跳过兼容性预检"
        return 0
    fi

    jre_major=$(java -XshowSettings:properties -version 2>&1 \
        | awk -F'= *' '/java.specification.version/ {print $2}' | tr -d ' ')
    jre_supported=$((jre_major + 44))

    if [ "$required" -gt "$jre_supported" ]; then
        log_error "velocity.jar 需要 Java $((required - 44))（class file ${required}.0），本镜像只有 Java ${jre_major}（最高 ${jre_supported}.0）。请升级镜像的 JDK 版本后重试。"
    fi

    log_success "JAR 兼容性预检通过（需要 Java $((required - 44))，当前 Java ${jre_major}）"
}

# 显示配置信息
show_config_info() {
    log_info "=== 配置信息 ==="
    log_info "Java 版本: $(java -version 2>&1 | head -n1)"
    log_info "工作目录: $(pwd)"
    log_info "文件信息:"
    log_info "  - velocity.jar: $(ls -lh /app/velocity.jar | awk '{print $5}')"
    log_info "  - velocity.toml: $(ls -lh /app/velocity.toml | awk '{print $5}')"
    log_info "  - forwarding.secret: $(cat /app/forwarding.secret | wc -c) 字符"

    # 显示插件信息（只统计根层，libs/ 里的是依赖缓存不是插件）
    local plugin_count=$(find /app/plugins -maxdepth 1 -name "*.jar" 2>/dev/null | wc -l)
    log_info "  - 插件数量: $plugin_count"

    echo "=================="
}

# 主函数
main() {
    log_info "🚀 启动 Velocity 服务器容器..."
    echo "镜像构建时间: $(date)"
    echo

    # 检查环境变量
    check_required_env

    # 下载核心文件
    download_file "$VELOCITY_JAR_URL" "/app/velocity.jar" "Velocity JAR"
    download_file "$VELOCITY_CONFIG_URL" "/app/velocity.toml" "Velocity 配置文件"
    download_file "$FORWARDING_SECRET_URL" "/app/forwarding.secret" "转发密钥文件"

    # 下载插件（如果提供了URL）
    if [ -n "$PLUGINS_ZIP_URL" ]; then
        download_and_extract_plugins
    else
        log_warning "跳过插件下载（未设置 PLUGINS_ZIP_URL）"
    fi

    # 验证文件
    verify_files

    # 显示配置信息
    show_config_info

    # 启动 Velocity
    log_success "🎯 启动 Velocity 服务器..."
    echo "=========================================="
    exec java ${JAVA_OPTS:-} -jar /app/velocity.jar
}

# 捕获信号以优雅关闭
trap 'log_warning "收到停止信号，正在关闭服务器..."; exit 0' SIGTERM SIGINT

# 运行主函数
main "$@"
