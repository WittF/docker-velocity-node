# docker-velocity-node

Velocity 中转节点镜像。镜像本身**不打包** Velocity 和插件——容器每次启动时按环境变量给出的 URL 现下 `velocity.jar` / `velocity.toml` / `forwarding.secret` / `plugins.zip`，所以更新一份网盘文件就能让全部节点跟着变。

镜像：`wittf/velocity-node`（同步推送 Docker Hub 与 `ghcr.io/wittf/velocity-node`）

## 为什么有这个仓库

镜像此前没有仓库、没有构建流水线，JDK 版本改不动也查不到，因此补上。

要解决的具体问题是：换用为 MC 26.2 编译的 Velocity 后，如果镜像 JRE 版本偏低，Velocity 主类会直接加载失败——

```
java.lang.UnsupportedClassVersionError: com/velocitypowered/proxy/Velocity
  has been compiled by a more recent version of the Java Runtime (class file version 69.0),
  this version of the Java Runtime only recognizes class file versions up to 65.0
```

配合 `restart: unless-stopped`，节点会陷入崩溃重启循环，对外表现为端口拒绝连接，而唯一的线索只有这一段堆栈。

## 关键约束

**镜像的 JDK 版本必须 >= velocity.jar 的编译目标版本。** 换 Velocity 版本前先确认这一条。

对照关系：class file 版本 = Java 主版本 + 44。

| Velocity 编译目标 | class file | 需要镜像 JDK |
| --- | --- | --- |
| Java 17 | 61.0 | >= 17 |
| Java 21 | 65.0 | >= 21 |
| Java 25 | 69.0 | >= 25 |

本镜像当前提供 **Zulu JDK 25**。

两道防线保证这个坑不会再重演：

1. **启动前预检**：`entrypoint.sh` 会读 `velocity.jar` 主类的 class file 版本，和本机 JRE 比对，不匹配时打印一句人话再退出，而不是丢一段 `LinkageError` 堆栈。
2. **CI 门禁**：workflow 里断言镜像 JDK 主版本 >= 25，低于就直接构建失败。

## 环境变量

| 变量 | 必填 | 说明 |
| --- | --- | --- |
| `VELOCITY_JAR_URL` | ✅ | Velocity JAR 直链 |
| `VELOCITY_CONFIG_URL` | ✅ | `velocity.toml` 直链 |
| `FORWARDING_SECRET_URL` | ✅ | `forwarding.secret` 直链（modern 转发密钥，需与后端一致） |
| `PLUGINS_ZIP_URL` | ➖ | 插件包直链，不设则跳过插件 |
| `PLUGINS_PRUNE` | ➖ | 默认 `true`。见下方说明 |
| `JAVA_OPTS` | ➖ | 追加到 `java` 命令的 JVM 参数 |

### 关于 `PLUGINS_PRUNE`

插件目录是持久卷。旧版 entrypoint 直接 `unzip -o` 叠加，旧 jar 永远不会被清掉，于是同一插件多版本共存。**Velocity 遇到同 id 多版本不报错，而是按目录扫描顺序静默挑一个**，实测常常挑中旧版——表现就是"插件明明更新了却没生效"，且没有任何告警。

默认 `PLUGINS_PRUNE=true` 让 `plugins.zip` 成为唯一事实来源：解压前把根层已有 jar 归档到 `plugins/.superseded/`，解压后根层只剩 zip 里那一份。插件的配置目录和 `libs/` 依赖缓存不受影响。需要旧行为设 `PLUGINS_PRUNE=false`。

## 用法

```yaml
services:
  velocity:
    image: wittf/velocity-node:latest
    container_name: velocity
    stdin_open: true
    tty: true
    ports:
      - "25565:25565"      # 左边换成本节点对外的端口
    environment:
      - VELOCITY_JAR_URL=https://example.com/velocity.jar
      - VELOCITY_CONFIG_URL=https://example.com/velocity.toml
      - FORWARDING_SECRET_URL=https://example.com/forwarding.secret
      - PLUGINS_ZIP_URL=https://example.com/plugins.zip
    restart: unless-stopped
    volumes:
      - velocity_logs:/app/logs
      - velocity_plugins:/app/plugins
    networks:
      - velocity_network

volumes:
  velocity_logs:
  velocity_plugins:

networks:
  velocity_network:
    driver: bridge
```

容器内 Velocity 固定监听 `25565`，对外端口由 `ports` 左值决定——排查连不上时注意别对着 25565 测。

## 发版

推 `main` 触发，`semantic-release` 按 conventional commits 定版本，构建通过后同时推 Docker Hub 和 GHCR，打 `latest` / `X` / `X.Y` / `X.Y.Z`。

需要仓库 secrets：`DOCKERHUB_USERNAME`、`DOCKERHUB_TOKEN`（GHCR 用内置 `GITHUB_TOKEN`）。
