class_name PvPost
extends RefCounted

## C 层「全屏 post」参数表：CRT 转场 / 色差 / 颗粒 / 辉光 / glitch。
##
## 参考实现：电影侧 `tuikit.py:L441-447`（扫描线）/ `L453-465`（暗角）/ `L468-476`（`post()`：
## 残影 + 辉光）、`transitions.py:L163-175`（crt 开关机转场）、`tui_live.py:L155-156`
## （`SCAN_DIM` / `VIG_FLOOR`）。
##
## **分工（`tools/ref/c_layer_plan.md` §7 Q6 拍板）**：
##   * 扫描线与暗角**继续由 `PvScreen.refresh_dim()` 的 `dim` 场负责**，post shader 不重复做，
##     否则会叠出双层扫描线；
##   * post 只加 CRT 转场、色差、颗粒、辉光、glitch 这五项。
##
## 全部是纯函数（数值进、数值出），headless 可逐值断言；真正的像素运算在
## `shaders/post_fullscreen.gdshader` 里。

## crt 转场只发生在这两个「机器被开关」的硬切上（`direction.py:L176`、`L207`），各 12 帧。
const CRT_SHOTS := ["shot_eggplant", "shot_grpo"]
const CRT_FRAMES := 12
const CRT_DUR := CRT_FRAMES / 24.0     # 0.5 s @ 24 fps


## post 总开关：挂在 `X`（FX 总开关）之下，可用 `PV.FX["post"]` 单独关。
static func enabled() -> bool:
	return bool(PV.FX["on"]) and bool(PV.FX.get("post", true))


## `transitions.py:L163-175` 的进度：`-1` = 不在转场里；`[0,1)` = 正在压线/展开。
## `p < 0.5` 把旧画面压成中间一条线，`p >= 0.5` 把新画面从线展开；全程画一条白线。
static func crt_progress(t: float, ent: Dictionary) -> float:
	if ent.is_empty():
		return -1.0
	if not CRT_SHOTS.has(str(ent.get("name", ""))):
		return -1.0
	var el := t - float(ent.get("start", 0.0))
	if el < 0.0 or el >= CRT_DUR:
		return -1.0
	return el / CRT_DUR


## 数值版：`loud/kick/flux` 都来自 `data/features.json`（48 Hz）。
## `err` = 该镜头 `alert=="err"`（`tui_live` 的红系统）。
static func params(t: float, loud: float, kick: float, flux: float, err: bool,
		crt: float = -1.0) -> Dictionary:
	var chroma := 0.06 + 0.12 * clampf(loud, 0.0, 1.0)
	var glitch := 0.0
	if err:
		chroma = 0.35 + 0.50 * clampf(kick, 0.0, 1.0)
		glitch = 0.15 + 0.60 * clampf(flux, 0.0, 1.0)
	return {
		"enabled": enabled(),
		"time": t,
		"chroma": chroma,
		"grain": 0.03 + 0.05 * clampf(loud, 0.0, 1.0),
		"glow": 0.12 + 0.35 * clampf(kick, 0.0, 1.0),
		"glitch": glitch,
		"crt": crt,
		"err": err,
	}


## 从数据表取特征再算参数（主场景用）。
static func params_at(t: float, ent: Dictionary, d: PvData) -> Dictionary:
	var loud := 0.0
	var kick := 0.0
	var flux := 0.0
	if d != null:
		loud = d.feat(t, "loud")
		kick = d.feat(t, "kick")
		flux = d.feat(t, "flux")
	var err := (not ent.is_empty()) and str(ent.get("alert", "")) == "err"
	return params(t, loud, kick, flux, err, crt_progress(t, ent))
