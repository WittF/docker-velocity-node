# Velocity 中转节点镜像
# 运行时从远端 URL 拉取 velocity.jar / velocity.toml / forwarding.secret / plugins.zip，
# 因此镜像本身只负责提供正确的 JRE 和启动流程。
#
# ⚠️ JDK 版本必须 >= Velocity jar 的编译目标，否则容器会以
#    UnsupportedClassVersionError 崩溃重启。当前 Velocity(MC 26.2 兼容版) 需要 Java 25。

FROM azul/zulu-openjdk:25-latest AS jdk25

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        unzip \
        tzdata \
        locales \
    && localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8 \
    && ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    && rm -rf /var/lib/apt/lists/*

# 从官方 Azul 镜像复制 Zulu JDK 25
COPY --from=jdk25 /usr/lib/jvm/zulu25 /usr/lib/jvm/zulujdk-25

ENV JAVA_HOME=/usr/lib/jvm/zulujdk-25
ENV PATH=$JAVA_HOME/bin:$PATH

RUN java -version

WORKDIR /app

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

EXPOSE 25565

ENTRYPOINT ["/app/entrypoint.sh"]
