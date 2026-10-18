// ================================================================
// Screen
// ================================================================
// 来源   https://godotshaders.com/shader/screen/
// 作者   Mincho1452  https://godotshaders.com/author/mincho1452/
// 发布   2026-03-22
// 类型   canvas_item
// 许可   cc0
// Godot  4.6
// 标签   screen
// ================================================================
// 由 shader_capture 抓取自 godotshaders.com，下方代码原样保留、未做修改。
// ================================================================

shader_type canvas_item;

// ═══════════════════════════════════════════════════════════════
//  BROKEN SCREEN — Godot 4 CanvasItem Shader
//  Uso: aplícalo a un ColorRect o TextureRect que cubra
//  toda la pantalla. Conecta la textura de tu viewport
//  en "screen_texture" para el efecto de post-processing.
// ═══════════════════════════════════════════════════════════════

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

// ── Parámetros ajustables desde el Inspector de Godot ───────────
uniform vec2  impact_point    = vec2(0.42, 0.60);  // centro del golpe (0..1)
uniform float crack_scale     : hint_range(0.1, 4.0) = 1.2;
uniform float distort_amount  : hint_range(0.0, 0.08) = 0.028;
uniform float darkness        : hint_range(0.0, 1.0)  = 0.60;
uniform float chroma_strength : hint_range(0.0, 0.02) = 0.008;
uniform float crack_radius    : hint_range(0.0, 1.5)  = 0.38;
uniform float burn_strength   : hint_range(0.0, 1.0)  = 0.80;
uniform float glitter_amount  : hint_range(0.0, 1.0)  = 0.6;
uniform float scanline_strength : hint_range(0.0, 0.2) = 0.06;
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.65;
uniform float time_scale      : hint_range(0.0, 4.0)  = 1.0;

// ── Hash & noise ─────────────────────────────────────────────────
float hash(vec2 p) {
    p = fract(p * vec2(127.1, 311.7));
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

vec2 hash2(vec2 p) {
    return fract(sin(vec2(
        dot(p, vec2(127.1, 311.7)),
        dot(p, vec2(269.5, 183.3))
    )) * 43758.5453);
}

vec3 hash3(vec2 p) {
    return fract(sin(vec3(
        dot(p, vec2(127.1, 311.7)),
        dot(p, vec2(269.5, 183.3)),
        dot(p, vec2(419.2, 371.9))
    )) * 43758.5453);
}

// ── Voronoi F1, F2, F3 ───────────────────────────────────────────
vec3 voronoi(vec2 x) {
    vec2 ip = floor(x);
    vec2 fp = fract(x);
    vec3 res = vec3(8.0);
    for (int j = -2; j <= 2; j++) {
        for (int i = -2; i <= 2; i++) {
            vec2 b = vec2(float(i), float(j));
            vec2 r = b + hash2(ip + b) - fp;
            float d = dot(r, r);
            if (d < res.x) {
                res.z = res.y; res.y = res.x; res.x = d;
            } else if (d < res.y) {
                res.z = res.y; res.y = d;
            } else if (d < res.z) {
                res.z = d;
            }
        }
    }
    return sqrt(res);
}

// ── ID única por celda Voronoi (para propiedades por shard) ──────
vec2 voronoiID(vec2 x) {
    vec2 ip = floor(x);
    vec2 fp = fract(x);
    float minD  = 8.0;
    vec2 cellID = vec2(0.0);
    for (int j = -2; j <= 2; j++) {
        for (int i = -2; i <= 2; i++) {
            vec2 b = vec2(float(i), float(j));
            vec2 r = b + hash2(ip + b) - fp;
            float d = dot(r, r);
            if (d < minD) {
                minD   = d;
                cellID = ip + b;
            }
        }
    }
    return cellID;
}

// ── Borde de grieta (ancho) ──────────────────────────────────────
float crackEdge(vec2 uv, float scale, float seed) {
    vec3 v    = voronoi(uv * scale + seed);
    float edge = v.y - v.x;
    return 1.0 - smoothstep(0.0, 0.028, edge);
}

// ── Micro-fractura (línea muy fina + halo) ───────────────────────
float crackThin(vec2 uv, float scale, float seed) {
    vec3 v    = voronoi(uv * scale + seed);
    float edge = v.y - v.x;
    float thin = 1.0 - smoothstep(0.0,  0.007, edge);
    float glow = 1.0 - smoothstep(0.007, 0.045, edge);
    return thin + glow * 0.3;
}

// ── Normal del vidrio (gradiente del campo de distancia) ─────────
vec2 glassNormal(vec2 uv, float scale, float seed) {
    float eps = 0.0018;
    float c0  = crackEdge(uv,               scale, seed);
    float cx  = crackEdge(uv + vec2(eps, 0.0), scale, seed);
    float cy  = crackEdge(uv + vec2(0.0, eps), scale, seed);
    return vec2(cx - c0, cy - c0) / eps;
}

// ── Inclinación de prisma por shard ──────────────────────────────
vec2 shardPrism(vec2 uv, float scale, float seed, float amt) {
    vec2 id   = voronoiID(uv * scale + seed);
    vec3 rnd  = hash3(id);
    vec2 tilt = (rnd.xy * 2.0 - 1.0) * amt;
    float loose = smoothstep(0.45, 1.0, rnd.z);
    return tilt * loose;
}

// ── Especular Blinn-Phong por shard ─────────────────────────────
float shardSpecular(vec2 uv, float scale, float seed) {
    vec2 id  = voronoiID(uv * scale + seed);
    vec3 rnd = hash3(id);
    vec3 nor = normalize(vec3(rnd.xy * 2.0 - 1.0, 1.8 + rnd.z));
    vec3 lit = normalize(vec3(0.5, 0.8, 1.0));
    vec3 viw = vec3(0.0, 0.0, 1.0);
    vec3 h   = normalize(lit + viw);
    return pow(max(dot(nor, h), 0.0), 48.0);
}

// ── Fresnel en borde de grieta ───────────────────────────────────
float fresnelEdge(vec2 uv, float scale, float seed) {
    vec3 v = voronoi(uv * scale + seed);
    return 1.0 - smoothstep(0.0, 0.055, v.y - v.x);
}

// ════════════════════════════════════════════════════════════════
void fragment() {
    vec2 uv     = UV;
    // Godot UV tiene Y invertido respecto a Shadertoy — corregimos:
    vec2 imp    = vec2(impact_point.x, 1.0 - impact_point.y);
    float dist  = length(uv - imp);
    float s     = crack_scale;
    float T     = TIME * time_scale;

    // ── 1. Máscara de radio (las grietas solo aparecen si dist < radius) ──
    float radiusMask = 1.0 - smoothstep(crack_radius * 0.7, crack_radius, dist);

    // ── 2. Capas de grietas ──────────────────────────────────────
    float proximity = 1.0 + 5.5 * smoothstep(0.30, 0.0, dist);

    float c1 = crackEdge(uv, s * 3.0,            0.00);
    float c2 = crackEdge(uv, s * 5.5,            3.71);
    float c3 = crackEdge(uv, s * 10.0,           8.13);
    float c4 = crackEdge(uv, s * 20.0*proximity, 1.23);
    float c5 = crackEdge(uv, s * 38.0*proximity, 5.55);

    float thin1 = crackThin(uv, s * 58.0*proximity, 2.17);
    float thin2 = crackThin(uv, s * 85.0*proximity, 7.93);
    float micro = (thin1 + thin2 * 0.5) * smoothstep(0.26, 0.0, dist);

    float cracks = max(
        max(max(c1, c2 * 0.9), c3 * 0.75),
        max(c4, c5) * smoothstep(0.35, 0.0, dist)
    );
    cracks = max(cracks, micro * 0.65);
    cracks *= radiusMask;

    // ── 3. Desplazamiento de refracción ─────────────────────────
    vec2 nor    = glassNormal(uv, s * 5.5, 3.71) * 0.65
                + glassNormal(uv, s * 3.0, 0.00) * 0.35;
    nor *= cracks * distort_amount;

    vec2 prism1 = shardPrism(uv, s * 5.5,  3.71, distort_amount * 0.85);
    vec2 prism2 = shardPrism(uv, s * 3.0,  0.00, distort_amount * 0.40);
    vec2 prismT = (prism1 + prism2) * smoothstep(0.42, 0.0, dist) * radiusMask;

    vec2 shift  = nor + prismT;

    // ── 4. Aberración cromática por shard ────────────────────────
    vec2 chromaDir = normalize(uv - imp + 0.0001);
    vec2 shardID   = voronoiID(uv * s * 5.5 + 3.71);
    float cVar     = hash(shardID) * 0.5 + 0.5;
    float cAmt     = chroma_strength * cracks * cVar;
    vec2 ca        = chromaDir * cAmt;

    // ── 5. Samplear la pantalla con aberración ───────────────────
    // SCREEN_UV en Godot 4 = coordenada de la textura de pantalla
    vec2 baseUV = SCREEN_UV + shift;
    float scR   = texture(screen_texture, baseUV + ca  ).r;
    float scG   = texture(screen_texture, baseUV        ).g;
    float scB   = texture(screen_texture, baseUV - ca  ).b;
    vec3  scene = vec3(scR, scG, scB);

    // ── 6. Color del vidrio roto ─────────────────────────────────
    // Tinte único por shard
    vec3 shardTint = hash3(shardID) * vec3(0.04, 0.07, 0.13);
    vec3 glassBase = vec3(0.012, 0.022, 0.048) + shardTint;

    // Mezcla escena + vidrio oscuro en las grietas
    vec3 glass = mix(scene, glassBase, cracks * darkness);

    // Fresnel en bordes
    float fres = fresnelEdge(uv, s * 5.5, 3.71);
    glass += vec3(0.78, 0.90, 1.00) * fres * 0.55 * radiusMask;

    // Especular por shard
    float spec  = shardSpecular(uv, s * 5.5, 3.71) * 0.65
                + shardSpecular(uv, s * 3.0, 0.00) * 0.35;
    glass += vec3(0.88, 0.94, 1.00) * spec * cracks * 0.85;

    // ── 7. Zona de impacto quemada ───────────────────────────────
    float burn = 1.0 - smoothstep(0.0, 0.19, dist) * burn_strength;
    glass *= burn;

    // ── 8. Polvo de vidrio (micro-glitter en bordes) ─────────────
    float glitter = step(1.0 - glitter_amount * 0.03,
                         hash(floor(uv * 820.0)));
    glitter *= cracks;
    glass += vec3(0.90, 0.96, 1.00) * glitter * 0.55;

    // ── 9. Glitch de líneas horizontales ────────────────────────
    float glitchRow = step(0.968,
        hash(vec2(floor(uv.y * 18.0), floor(T * 9.0))));
    glass = mix(glass, 1.0 - glass, glitchRow * 0.14);

    // ── 10. Scanlines ────────────────────────────────────────────
    float scan = 0.5 + 0.5 * sin(UV.y * VIEWPORT_SIZE.y * 3.14159);
    glass *= 1.0 - scanline_strength * (1.0 - scan);

    // ── 11. Vignette ─────────────────────────────────────────────
    float vig = 1.0 - smoothstep(0.32, 1.0, length(uv - 0.5) * 1.7);
    glass = mix(glass, glass * vig, vignette_strength);

    COLOR = vec4(clamp(glass, 0.0, 1.0), 1.0);
}
