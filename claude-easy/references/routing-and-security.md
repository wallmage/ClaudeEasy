# ClaudeEasy 分流与安全策略

> 读取路由：任务涉及共同国内直连、DNS、TUN、代理组、AI 规则或 WebRTC 时读取本文件。所有任务先读取 [policy-core.md](policy-core.md)；本文件不重复共同边界。

## DNS 与 TUN

档位 1、2、3 的共同国内域名直连基线由 `policy.json` 的 `cn_domain_provider` 和 `direct_resolvers` 生成：安装受管国内域名规则提供器，让该规则提供器通过当前主代理组更新；国内域名路由到 `DIRECT`，其 `nameserver-policy` 与 `direct-nameserver` 使用同一组直连解析器，并关闭 `direct-nameserver-follow-policy`。具体名称、地址、路径、更新间隔和解析器值不得在本文复制。

档位 3 的追加策略：

```yaml
ipv6: false
tun:
  enable: true
  stack: system
  dns-hijack:
    - any:53
    - tcp://any:53
  auto-route: true
  auto-detect-interface: true
  strict-route: true
dns:
  enable: true
  ipv6: false
  respect-rules: true
  use-hosts: true
  use-system-hosts: true
```

补丁不创建安全代理组。`DNS` 出站只把请求交给 Mihomo 内部 DNS 模块，不是远端代理。Fake-IP 模式会在连接规则判定前解析域名，因此三个档位都必须让 `nameserver-policy` 与路由引用同一个受管规则提供器，不能只设置 `direct-nameserver`。档位 3 另保留 `geosite:cn` 后备；普通国外查询使用带原主代理组标签的受管 DoH，AI 域名查询使用带 AI 分组标签的同一套受管 DoH。这样国内直连网站获得大陆 CDN，AI 的解析请求和网页连接使用同一个 AI 出口。

`policy.json` 的 `resolvers` 与 `direct_resolvers` 都直接连接解析器 IP，无需先解析解析器域名，避免引导解析错误引发证书失败。所有查询都使用 HTTPS，不加入广告拦截，不发送 ECS。

`default-nameserver` 和 `proxy-server-nameserver` 属于网络启动边界，存在时必须是列表，安全用户值必须保留。`proxy-server-nameserver` 缺失、类型不对，或任一值使用 `system`、明文 DNS、旧版补丁写入的固定境外组合时，统一迁移到策略中的大陆 IP DoH，并带 `#DIRECT` 直接连接；这组解析器不依赖系统 DNS、明文 53 或解析器域名引导。已有 `default-nameserver` 类型不对或含同类危险值时也迁移，字段缺失时不新增。这样节点域名解析不会重进 AdGuard、TUN `dns-hijack` 和 Mihomo Fake-IP 链。

`direct-nameserver` 不保留原值，统一写成策略文件中的大陆 IP DoH；同时把 `direct-nameserver-follow-policy` 设为 `false`。`nameserver-policy` 中的 `geosite:cn` 也必须覆盖为同一组解析器，避免 Fake-IP 初次解析先落到代理侧。这样不会让用户原有的 `system`、明文 DNS 或代理 DNS 使国内域名继续泄露或获得境外 CDN。直连 DoH 会让阿里或 DNSPod 看到国内域名查询，但本地运营商只能看到加密的 HTTPS 连接；这属于受管的分流，不是意外泄露。

如 `nameserver-policy` 把多个域名写在同一个逗号分隔键中，拆成独立键。只有当解析器片段指向已知的非直连节点，或指向依赖关系中无法到达 `DIRECT` 的静态代理组时，才保留这个分流目标；解析器地址统一换成策略文件中的三个 IP DoH。这样不会因为 `dns.google`、`cloudflare-dns.com` 等解析器域名被错误解析而让所有新域名一起失败，也不会继续依赖某些节点会拒绝的 `8.8.8.8`、`1.1.1.1`。DNS 静态安全判断不执行订阅提供的 `exclude-filter`；只要过滤器非空，该组就无法静态证明，解析器改用受管 DoH。带 `use`、`include-all` 或其他动态成员的组同样改用受管 DoH。只有不带过滤器的空静态组，才接受明确指向安全内联代理的 `empty-fallback`；默认的 `COMPATIBLE` 不合格。Mihomo 的 `exclude-type` 只作用于自动纳入的节点，这些动态组本来就不保留。

`#h3=true` 可以保留。除受管的 `direct-nameserver` 外，`#en0`、`#RULES`、未知名称、明文 DNS、`DIRECT`、`DNS` 出站和没有代理组标签的查询都改为代理侧受管 DoH。带 `skip-cert-verify=true` 的解析器跳过证书校验；带 `ecs` 或 `ecs-override` 的解析器会发送客户端子网信息。这三类参数也改为受管 DoH。

不要为某个打不开的网站添加专用 DNS 例外，也不要为测速成绩添加国内 DNS 例外。国内 CDN 错位时检查 `direct-nameserver` 和实时出站，不添加站点规则。同类网站一起出现 `SERVFAIL` 时，应检查整组解析器和当前节点；某个配置在另一节点上恢复，通常是节点故障，不要误改 DNS。最后以真实泄漏测试结果为准。

## 主代理组

主组候选包含 Mihomo 的 `select`、`url-test`、`fallback` 和 `load-balance` 代理组。优先按以下顺序选择非 AI、非本工具受管的组：

1. 最后一个 `MATCH` 指向的非 `DIRECT` 代理组；
2. 被宽泛规则（`MATCH`、`GEOIP`、`GEOSITE` 或广域 `RULE-SET`）引用超过一次的代理组；
3. `Proxy`、`PROXY`、`Final`、`Fallback`、`节点选择`、`节点列表` 或 `兜底分流`；
4. 第一个包含代理成员或代理提供者的代理组。

显式 `proxies` 不受导入过滤器影响；`use`、`include-all`、`include-all-proxies` 和 `include-all-providers` 按 Mihomo 的来源与过滤语义判断。危险分隔符或控制字符的组名通过受管选择器安全引用，不能直接拼入 DNS 或规则 DSL。找不到独立主组时，再选择含代理成员或代理提供者的 AI 命名组或本工具受管组；若仍没有，则使用第一个 Mihomo 合法代理组。这样非空且通过 Mihomo 校验的代理组集合总能获得主组，共同基线不会因订阅使用自动代理组或只有 AI 分组而静默跳过。最后选择只发生在代理组之间，不猜单个节点。若主组就是 AI 分组，普通与 AI 流量暂时共用它；不得制造代理组自引用。

## AI 组

先寻找订阅已有的可选 AI 分组。名称匹配策略文件中的 AI 组名称，或包含独立的 `AI`、`OpenAI`、`人工智能` 时，视为已有 AI 分组。已有时直接复用，只补全规则；分组类型、成员、顺序、图标和当前选择全部保持原样。

只有确认没有可选 AI 分组时，才创建 `🤖 AI · ClaudeEasy`。新组直接列出订阅中全部有效的内联代理节点，并通过 `use` 接入全部有效的 `proxy-providers`。不得只把主代理组或“节点列表”作为唯一成员；否则用户无法让普通流量与 AI 流量选择不同节点。名称被其他代理组或内联代理占用时使用没有冲突的编号。重复运行必须复用已创建的组，不能产生重名。没有任何有效内联节点或代理提供者时不创建分组，保持原文件不变并说明原因。

AI 组负责 OpenAI、ChatGPT、Codex、Claude、Anthropic，以及策略文件中列出的 Google AI 和相关服务流量。

## 节点建议

用户原有 AI 分组的成员保持不变。只有 ClaudeEasy 自己新建或旧版创建的 AI 分组会填入全部可用节点和代理提供者。补丁不得调用控制器切换节点，也不得替用户选择台湾、日本或任何家宽节点。

AI 分组的用途是分开普通流量和 AI 流量：主代理组可以选择低倍率节点用于浏览、下载和视频，AI 分组可以由用户单独选择信誉更好的家宽节点。补丁只提供完整选项，不替用户决定。

聊天中说明家宽通常比数据中心节点更适合 AI 服务；如果用户有台湾家宽，优先建议台湾，没有台湾时可建议日本。建议只写在聊天中，最终选择完全交给用户。

## AI 规则

唯一数据来源是 [policy.json](policy.json)。Windows 脚本中的策略块由本地生成器写入，并由一致性测试检查，不能手工维护另一份规则。

规则覆盖范围、当前规则、迁移规则和禁止整体交给 AI 组的通用域名，分别只读取 `policy.json` 的 `ai_rules`、`legacy_ai_rules` 与 `forbidden_ai_domains`；本文不复制具体域名、网段或规则文本。

不得把整站 `sentry.io`、`auth0.com`、`segment.io`、`intercom.io`、Stripe、Cloudflare Challenge、SendGrid、WorkOS 等共享服务交给 AI 组。只保留第一方域名和能确认专门服务于 AI 产品的精确主机名。
从旧策略升级时，只迁移 `legacy_ai_rules` 指定、且目标仍是补丁自有 AI 组的规则，并写入 `ai_rules` 的当前值。相同旧规则若指向用户组，必须保留；对应 DNS 旧键也只在解析器仍指向补丁自有安全组时删除。

只删除目标为受管 AI 组的上述规则。其他用途的规则保持不变。

订阅把同一批 AI 域名交给主代理组的通用规则必须替换，否则会让 AI 流量绕过独立 AI 分组。用户明确写给其他非主代理目标的同类规则保持原目标，并排在补丁规则之前。AI 明确规则必须出现在国内直连、GEO、所有 `RULE-SET` 和 `MATCH` 之前。

## WebRTC

依次加入两条规则：

```text
NETWORK,UDP,<AI 分组>
NETWORK,UDP,REJECT
```

第一条的目标使用 AI 分组，不创建安全代理分组。把两条都放在规则列表开头，确保更靠后的 `NETWORK,udp,DIRECT`、`DST-PORT,3478,DIRECT`、进程规则和任意 `RULE-SET` 都不能先放行 UDP。已有规则不删除；除了与补丁 AI 规则同键的用户规则会前移以保留优先权，其余规则保持原目标和相对顺序。

AI 分组当前选择必须是代理节点，不能是 `DIRECT`。节点不支持 UDP 时 Mihomo 继续匹配拒绝兜底，不得写成 WebRTC 已验证；它不会因此改走本地直连。补丁不得切换分组或节点，只能检查并如实报告当前状态。

不能按浏览器应用或 AI 域名单独防 WebRTC。同一个浏览器会同时访问国内和 AI 网站，而 STUN 连接的目标与原网页域名分离，Mihomo 无法判断连接来自哪个标签页。TCP 和 DNS 按域名分流；WebRTC 防护必须覆盖所有 UDP。HTTP/3/QUIC 也经过 AI 分组；国内网页的 TCP 与 DNS 仍然直连。在线游戏、语音和视频通话也可能受影响，安装前后的说明都必须写明这个影响。

AI 网页流量、AI 域名 DNS 和所有 UDP 使用同一 AI 分组。多个结果如果全是代理出口，不属于真实 IP 泄漏；单一结果更容易确认。

本地区域指纹页不得把 WebRTC 发现的公网 IP 发送给归属地查询或其他第三方服务。页面必须在创建 `RTCPeerConnection` 前明确列出 `stun.l.google.com`、`stun1.l.google.com` 和 `stun.cloudflare.com`，说明 Google 和 Cloudflare 会看到连接源公网 IP，并只在用户点击“开始检测并运行 WebRTC 测试”或同等明确的重新扫描按钮后连接这些 STUN 服务。CSP 必须禁止其他网络请求。没有公网 IP 时 WebRTC 项计 `+0`；发现公网 IP 但无法在本地确认归属地时写成“无法读取”和未知权重，不能为了补齐分数外发该 IP。
