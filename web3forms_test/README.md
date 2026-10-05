# Web3Forms 测试项

在 Godot 4 里调用 [Web3Forms](https://docs.web3forms.com/getting-started/api-reference) 表单接口的最小实现 + 一个能直接点着玩的面板。

本目录是独立新增的，没有改动工程里的任何其它文件（未动 `project.godot`、没有加 autoload、没有设主场景）。

## 文件

| 文件 | 作用 |
| --- | --- |
| `web3forms_client.gd` | 客户端。两个接口都实现了，处理 200 / 303 / 400 / 429 / 500 |
| `web3forms_test.tscn` + `.gd` | 测试面板，界面上填参数、点按钮发请求、看返回 |

## 怎么跑

用 Godot 4.7 打开工程，在文件系统里双击 `web3forms_test/web3forms_test.tscn`，按 **F6** 运行。

Access Key 已经预填好（官方说明这是公开 key，可以安全放在客户端代码里）。点「发送测试」，邮箱里就会收到邮件，面板下方会显示服务端返回的原文。

## 在自己的代码里用

```gdscript
const Web3Forms := preload("res://web3forms_test/web3forms_client.gd")

var client = Web3Forms.new()
add_child(client)                     # 必须先加入场景树
client.access_key = "your-access-key"
client.subject = "来自 Godot"
client.submit_completed.connect(func(r): print(Web3Forms.describe(r)))
client.submit({"name": "小明", "message": "你好"})
```

两个接口：

- **Access Key 方式**：`POST https://api.web3forms.com/submit`，`access_key` 放在请求体里。
- **Form ID 方式**：`POST https://api.web3forms.com/submit/{FORM_ID}`，填 `client.form_id` 即可，URL 里已经带了身份，不用再传 `access_key`（官方说明两者是同一个 UUID）。

保留字段都做成了属性：`email` / `subject` / `ccemail` / `replyto` / `redirect` / `botcheck` / `webhook`。其余字段用 `submit({...})` 或 `custom_fields` 传，保留字段优先级最高，同名会被覆盖。

回调拿到的 `result` 是个字典：

```
code          HTTP 状态码，0 表示没拿到响应
success       业务是否成功
message       服务端提示（400/429/500 的原因都在这里）
data          服务端回显的提交数据
redirect_url  303 时 Location 头里的跳转地址
raw           原始响应体
error         网络层错误说明，为空表示拿到了 HTTP 响应
```

## 两个实现细节

**303 不会自动跳转。** 客户端把 `max_redirects` 设为 `0`，收到 303 时原样返回，跳转地址在 `redirect_url` 里，由你决定要不要跟。想让它自己跟就设 `client.max_redirects = 8`。

**响应解析对两种形状都兼容。** 官方文档写的 200 是 `{"success":true,"body":{"data":{...},"message":"..."}}`，但线上实测返回的是扁平的 `{"success":true,"data":{...},"message":"..."}`；500 更是只返回 `{"message":"Internal server error"}`，连 `success` 字段都没有。解析时两种位置都会找一遍。

## 实测记录

用工程里预填的 key 真实提交过一次，返回：

```json
{"success":true,"data":{...},"message":"Form submitted successfully!"}
```

HTTP 200，邮件正常送达。另外也验证过：错误的 key 返回 400，不存在的 Form ID 走 URL 方式返回 500 —— 都能正确解析并落到 `submit_failed`。

## 关于附件

文档里的 `attachment` 是 PRO 功能，本项目**没有实现**。原因：Godot 的 `HTTPRequest.request()` 请求体类型是 `String`，二进制文件内容会被 UTF-8 编码破坏，必须换成低层的 `HTTPClient` 自己维护状态机。需要的话再加。
