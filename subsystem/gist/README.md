# Gist POST 请求测试项

参考 `F:\项目\测试\control.gd` 的实现，把「向 `gist.githubusercontent.com` 发请求、取回并解析 Gist 内容」这件事补齐成一个可复用客户端 + 一个能直接点着玩的面板 + 一套无头离线自测。

本目录是独立新增的，没有改动工程里的任何其它文件（未动 `project.godot`、没有加 autoload、没有设主场景）。

## 文件

| 文件 | 作用 |
| --- | --- |
| `gist_client.gd` | 客户端。支持 GET / POST，带代理、超时、重定向设置，输出连接 / 网络 / 请求三种状态 |
| `gist_test.tscn` + `.gd` | 交互面板，界面上填地址、选方法、发请求、看返回内容 |
| `tests/gist_smoke_test.tscn` + `.gd` | 无头离线自测，只测纯函数与状态机，不发真实网络请求 |

## 怎么跑

**面板（手动、需要外网）。** 用 Godot 4.7 打开工程，在文件系统里双击 `subsystem/gist/gist_test.tscn`，按 **F6** 运行。面板默认：

- 请求地址 = `GistClient.DEFAULT_ENDPOINT`（即 control.gd 里用的那个 Gist raw 地址）；
- 请求方法 = **POST**（对齐用户要求）；
- 代理 = `127.0.0.1:7890`（对齐 control.gd 里硬编码的代理，改成空表示直连）。

**无头自测（CI / 沙箱）。**

```powershell
godot --headless --path <项目> res://subsystem/gist/tests/gist_smoke_test.tscn
```

退出码 `0` = 全部通过，`1` = 有失败，`2` = 超时。

## 在自己的代码里用

```gdscript
const GistClient := preload("res://subsystem/gist/gist_client.gd")

var client = GistClient.new()
add_child(client)                                   # 必须先加入场景树
client.proxy_host = "127.0.0.1"                      # 需要走代理时再设
client.proxy_port = 7890
client.timeout = 20.0
client.request_completed.connect(func(r): print(GistClient.describe(r)))
client.request_gist("", HTTPClient.METHOD_POST)      # body 为空
```

`request_gist(body, method_override, url_override)` 的返回值为 `OK` 时表示请求已发出，结果看下面这些信号：

- `request_succeeded(result)` —— 2xx 且传输层成功；
- `request_failed(result)` —— 非 2xx（含 404 / 405 等异常响应）或传输层错误；
- `request_timed_out(result)` —— 传输层结果为超时；
- `request_completed(result)` —— 总是最后触发。

回调拿到的 `result` 是个字典：

```
code             HTTP 状态码，0 表示没拿到响应
success          是否成功（2xx 且传输层成功）
message          服务端提示或错误摘要（404 / 405 的原因都在这里）
content          Gist 的文本内容（raw 原文，或从 JSON 的 files 里抽出来的）
files            JSON 形状 Gist 的 files 字典，非 JSON 时为空
is_json          响应体是否被解析成 JSON
method           本次用的方法名（"GET" / "POST" …）
url              实际请求的地址
headers          响应头
raw              原始响应体
error            网络层错误说明，为空表示拿到了 HTTP 响应
transport_result HTTPRequest 的传输层结果码
timed_out        是否被判为超时
```

## 三种状态

| 状态 | 取值 | getter |
| --- | --- | --- |
| 请求状态 | `IDLE` / `PENDING` / `DONE` | `get_request_status()` / `get_request_status_text()` |
| 连接状态 | `DISCONNECTED` / `CONNECTING` / `CONNECTED` / `FAILED` | `get_connection_status()` / `get_connection_status_text()` |
| 网络状态 | 文字描述（网络可用 / 无法解析主机名 / 请求超时 …） | `get_network_status()` |

## 两个实现细节

**「POST 到 gist.githubusercontent」按异常响应处理。** `gist.githubusercontent.com/.../raw` 只服务 GET 原始内容；官方创建 / 更新 Gist 走的是 `POST https://api.github.com/gists`（需要 token）。按用户要求把请求默认设成 POST 后，raw 地址会返回 **405 Method Not Allowed**，客户端把它归入 `request_failed`，`message` 里写明「该方法不被允许（raw 地址只支持 GET）」。想正常取内容，把方法切回 GET 即可。

**响应解析兼容两种形状。** raw 地址返回纯文本，直接作为 `content`；若返回的是 GitHub API 形状的 JSON（`{"files": {...}}`），则从 `files` 里抽出第一个文件的 `content`。只在响应体看着像 JSON 时才解析，避免 HTML 错误页刷引擎报错。

## 与 control.gd 的差异

| 项 | `control.gd` | 本客户端 |
| --- | --- | --- |
| 代理 | 硬编码 `127.0.0.1:7890` | `proxy_host` / `proxy_port` 可配，空则直连 |
| 方法 | 注释里示范 POST，正文用 GET | GET / POST 可选，默认 POST |
| 内容解析 | 直接把 body 塞进 Label | `parse_gist()` 区分纯文本 / JSON |
| 状态 | 无 | 请求 / 连接 / 网络三种状态 |
| 错误处理 | 只有 `push_error` | 成功 / 失败 / 超时 / 异常响应分类 + 信号 |
