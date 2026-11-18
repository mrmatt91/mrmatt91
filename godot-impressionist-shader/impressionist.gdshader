// Impressionist oil-paint post-process for Godot 4.
//
// Repaints the finished frame as layers of opaque brush dabs: big loose
// strokes everywhere, then smaller ones only where the picture has detail.
// The dabs are then pulled toward a two-colour palette (cool shadows against
// warm lights), with a share of them flipped to the opposite colour so flat
// areas break up into flecks. Paint relief and canvas weave go on last.
//
// Setup: CanvasLayer > ColorRect (Full Rect, Mouse Filter = Ignore) with a
// ShaderMaterial using this shader. See README.md.

shader_type canvas_item;
render_mode unshaded;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;

group_uniforms brush;
/** Size of the largest dabs, as a fraction of screen height. */
uniform float stroke_size : hint_range(0.01, 0.12, 0.001) = 0.034;
/** How long dabs are compared to their width. */
uniform float stroke_length : hint_range(1.0, 4.0, 0.05) = 2.4;
/** How readily small strokes are added to pick out edges and features. */
uniform float detail : hint_range(0.0, 1.0, 0.01) = 0.6;
/** How strongly strokes turn to run along edges in the picture. */
uniform float edge_follow : hint_range(0.0, 1.0, 0.01) = 0.85;
/** Resting stroke direction in degrees (0 = horizontal). */
uniform float flow_angle : hint_range(-90.0, 90.0, 1.0) = 0.0;
/** How much the resting direction swirls across the canvas. */
uniform float flow_turbulence : hint_range(0.0, 1.0, 0.01) = 0.6;
/** Bristle streaks and ragged stroke ends. */
uniform float bristle : hint_range(0.0, 1.0, 0.01) = 0.65;
/** Stroke layers: 3 is the full look, 2 is cheaper, 1 is cheapest and loosest. */
uniform int layers : hint_range(1, 3) = 3;

group_uniforms palette;
/** 0 keeps the game's own colours, 1 repaints entirely in the two tints. */
uniform float palette_strength : hint_range(0.0, 1.0, 0.01) = 0.6;
uniform vec3 shadow_tint : source_color = vec3(0.16, 0.20, 0.62);
uniform vec3 light_tint : source_color = vec3(1.0, 0.82, 0.30);
/** Balance between the tints: raise for more shadow tint, lower for more light tint. */
uniform float palette_pivot : hint_range(0.0, 1.0, 0.01) = 0.6;
/** How much neighbouring dabs disagree in tint, hue and brightness. */
uniform float broken_color : hint_range(0.0, 1.0, 0.01) = 0.55;
uniform float saturation : hint_range(0.0, 2.0, 0.01) = 1.15;
/** Lifts blacks so the darkest paint stays coloured instead of black. */
uniform float black_lift : hint_range(0.0, 0.5, 0.01) = 0.06;

group_uniforms surface;
/** Thickness of the paint relief and its highlights. */
uniform float impasto : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float canvas_grain : hint_range(0.0, 1.0, 0.01) = 0.35;
/** Colour of the primed canvas that shows between strokes. */
uniform vec3 ground_tint : source_color = vec3(0.88, 0.72, 0.36);
uniform float ground_show : hint_range(0.0, 1.0, 0.01) = 0.3;

group_uniforms motion;
/** Re-randomise the strokes this many times a second (0 = strokes stay put). */
uniform float boil_fps : hint_range(0.0, 24.0, 1.0) = 0.0;
/** Slides the stroke pattern, in screen heights. Drive it from the camera to pin strokes to the world. */
uniform vec2 canvas_offset = vec2(0.0);

group_uniforms advanced;
/** Turn on if the viewport has "HDR 2D" enabled (screen colours are then linear). */
uniform bool linear_input = false;

// How decisively the stroke on top hides the ones beneath it.
const float STACKING = 6.0;

vec4 hash42(vec2 p) {
	vec4 p4 = fract(vec4(p.xyxy) * vec4(0.1031, 0.1030, 0.0973, 0.1099));
	p4 += dot(p4, p4.wzxy + 33.33);
	return fract((p4.xxyz + p4.yzzw) * p4.zywx);
}

float hash11(float x) {
	float h = fract(x * 0.1031);
	h *= h + 33.33;
	h *= h + h;
	return fract(h);
}

float noise1(float x) {
	float i = floor(x);
	float f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(hash11(i), hash11(i + 1.0), f);
}

float luma(vec3 c) {
	return dot(c, vec3(0.299, 0.587, 0.114));
}

vec3 to_linear(vec3 c) {
	return linear_input ? c : pow(max(c, vec3(0.0)), vec3(2.2));
}

vec3 from_linear(vec3 c) {
	return linear_input ? c : pow(max(c, vec3(0.0)), vec3(1.0 / 2.2));
}

// Oklab: lightness in x, green-red in y, blue-yellow in z.
vec3 rgb_to_oklab(vec3 c) {
	vec3 lms = vec3(
			0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b,
			0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b,
			0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b);
	lms = pow(max(lms, vec3(0.0)), vec3(1.0 / 3.0));
	return vec3(
			0.2104542553 * lms.x + 0.7936177850 * lms.y - 0.0040720468 * lms.z,
			1.9779984951 * lms.x - 2.4285922050 * lms.y + 0.4505937099 * lms.z,
			0.0259040371 * lms.x + 0.7827717662 * lms.y - 0.8086757660 * lms.z);
}

vec3 oklab_to_rgb(vec3 lab) {
	vec3 lms = vec3(
			lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z,
			lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z,
			lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z);
	lms = lms * lms * lms;
	return vec3(
			4.0767416621 * lms.x - 3.3077115913 * lms.y + 0.2309699292 * lms.z,
			-1.2684380046 * lms.x + 2.6097574011 * lms.y - 0.3413193965 * lms.z,
			-0.0041960863 * lms.x - 0.7034186147 * lms.y + 1.7076147010 * lms.z);
}

// Colours the screen cannot show are faded toward grey of the same lightness
// rather than clipped, which would shift their hue.
vec3 fit_gamut(vec3 rgb, float lightness) {
	float grey = clamp(lightness * lightness * lightness, 0.0, 1.0);
	vec3 d = rgb - vec3(grey);
	vec3 room = mix(vec3(grey), vec3(1.0 - grey), step(vec3(0.0), d));
	vec3 k = room / max(abs(d), vec3(0.00001));
	return vec3(grey) + d * min(1.0, min(k.r, min(k.g, k.b)));
}

// Paints one layer of dabs over `col`.
//   p         pixel position in screen heights (already offset by canvas_offset)
//   uv_scale  converts p-space lengths to screen UV
//   size      dab size in screen heights
//   px        screen height in pixels
//   keep      share of dabs that are always painted
//   gain      how quickly local contrast brings in the rest
// `aux` carries paint height in x, the dab's warm/cool nudge in y, a per-dab
// random value in z, and in w whether the dab takes the opposite tint.
void paint_layer(vec2 p, vec2 uv_scale, float size, float px, float aspect, float seed,
		float keep, float gain, inout vec3 col, inout vec4 aux) {
	float thick = size / stroke_size;
	float cell = size * 0.75; // dabs are larger than their spacing, so they overlap
	vec2 home = floor(p / cell);
	float lod = max(log2(cell * px) - 2.0, 0.0);
	float tap = 0.3 * cell;
	float turn = radians(flow_angle);

	vec3 sum_col = vec3(0.0);
	vec4 sum_aux = vec4(0.0);
	float sum_w = 0.0;
	float bare = 1.0;

	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 id = home + vec2(float(i), float(j));
			vec2 key = mod(id, 1024.0) + seed;
			vec4 r1 = hash42(key);

			// A dab reaches at most 1.2 cells from a centre that sits at least
			// 0.25 cells inside its own cell, so the 3x3 search never misses one.
			vec2 centre = (id + 0.5 + (r1.xy - 0.5) * 0.5) * cell;
			float half_len = cell * 1.2 * mix(0.6, 1.0, r1.z);
			vec2 q = p - centre;
			if (dot(q, q) > half_len * half_len) {
				continue;
			}

			// Three blurred taps around the centre give the dab its colour and
			// tell us which way the picture is changing underneath it.
			vec2 cuv = (centre - canvas_offset) * uv_scale;
			vec3 s0 = textureLod(screen_texture, cuv + vec2(0.0, tap) * uv_scale, lod).rgb;
			vec3 s1 = textureLod(screen_texture, cuv + vec2(-0.866, -0.5) * tap * uv_scale, lod).rgb;
			vec3 s2 = textureLod(screen_texture, cuv + vec2(0.866, -0.5) * tap * uv_scale, lod).rgb;
			vec3 paint = (s0 + s1 + s2) / 3.0;
			float contrast = length(s0 - s1) + length(s1 - s2) + length(s2 - s0);

			vec4 r2 = hash42(key + 311.7);
			float present = smoothstep(r2.x - 0.08, r2.x + 0.08, keep + (contrast - 0.04) * gain);
			if (present <= 0.0) {
				continue;
			}

			// Stroke direction. Angles are doubled while blending so that a
			// direction and its opposite count as the same stroke.
			float phi = turn + (r2.y - 0.5) * 0.9 + flow_turbulence * 1.3 *
					sin(dot(centre, vec2(2.1, 1.3)) + 2.0 * sin(dot(centre, vec2(-1.1, 2.7))));
			vec2 lean = vec2(cos(2.0 * phi), sin(2.0 * phi));
			vec2 grad = vec2((luma(s2) - luma(s1)) * 0.577, luma(s0) - 0.5 * (luma(s1) + luma(s2)));
			float steep = dot(grad, grad);
			vec2 along_edge = vec2(grad.y * grad.y - grad.x * grad.x, -2.0 * grad.x * grad.y) / max(steep, 0.000001);
			lean = mix(lean, along_edge, edge_follow * smoothstep(0.01, 0.06, sqrt(steep)));
			float ang = 0.5 * atan(lean.y, lean.x);
			vec2 dir = vec2(cos(ang), sin(ang));

			// Position inside the dab: u runs along it, v across, both -1..1.
			float u = dot(q, dir) / half_len;
			float v = dot(q, vec2(-dir.y, dir.x)) * aspect / half_len;

			// Bristles: clumps across the width carry different amounts of
			// paint and run dry at different lengths.
			float clump = noise1(v * 2.5 + r2.z * 97.0);
			float dry = noise1(v * 8.0 + r2.w * 61.0);
			float au = abs(u) / (1.0 - 0.45 * bristle * dry);
			float av = abs(v);
			float edge = au * au * au + av * av * av;
			float a = (1.0 - smoothstep(mix(0.5, 0.15, thick), 1.0, edge)) * present;

			vec4 r3 = hash42(key + 733.1);
			float streak = mix(1.0, 0.6 + 0.8 * clump, bristle);
			paint *= 1.0 + (r3.x - 0.5) * 0.14 + (streak - 1.0) * 0.3;
			float height = (1.0 - 0.6 * av * av) * streak * (0.8 + 0.4 * r3.w) * thick;

			// Warm/cool nudge: partly the dab's own, mostly shared with its
			// neighbours so borderline areas break into loose patches. A few
			// dabs take the opposite tint outright.
			float local = sin(dot(centre, vec2(9.1, 5.3)) + 2.0 * sin(dot(centre, vec2(-4.2, 7.7))));
			float nudge = 0.7 * local + 0.6 * (r3.y - 0.5);
			float flip = step(1.0 - 0.06 * broken_color * step(thick, 0.9), fract(r3.w * 17.0 + r1.w));

			float w = a * exp2(STACKING * r1.w);
			sum_col += paint * w;
			sum_aux += vec4(height, nudge, r3.z * 2.0 - 1.0, flip) * w;
			sum_w += w;
			bare *= 1.0 - a;
		}
	}

	if (sum_w > 0.0) {
		float cover = 1.0 - bare;
		col = mix(col, sum_col / sum_w, cover);
		aux = mix(aux, sum_aux / sum_w, cover);
	}
}

void fragment() {
	vec2 res = 1.0 / SCREEN_PIXEL_SIZE;
	vec2 uv_scale = vec2(res.y / res.x, 1.0);
	vec2 p = SCREEN_UV / uv_scale + canvas_offset;
	float seed = boil_fps > 0.0 ? mod(floor(TIME * boil_fps), 97.0) * 13.7 : 0.0;

	// Underpainting: a thin wash of the scene over the toned canvas. It only
	// shows where no stroke lands.
	vec3 wash = textureLod(screen_texture, SCREEN_UV, max(log2(stroke_size * res.y), 0.0)).rgb;
	vec3 col = mix(wash, ground_tint, ground_show);
	vec4 aux = vec4(0.0);

	float gain = mix(1.0, 9.0, detail);
	paint_layer(p, uv_scale, stroke_size, res.y, max(stroke_length * 0.72, 1.0), seed, 1.0, 0.0, col, aux);
	if (layers >= 2) {
		paint_layer(p, uv_scale, stroke_size * 0.55, res.y, stroke_length, seed + 19.0, 0.7, gain, col, aux);
	}
	if (layers >= 3) {
		paint_layer(p, uv_scale, stroke_size * 0.28, res.y, stroke_length, seed + 41.0, -0.05, gain, col, aux);
	}

	// Palette. Each dab is pulled toward the shadow tint or the light tint,
	// chosen mostly by its own warmth and then by its brightness, and nudged
	// at random so that neighbouring dabs disagree.
	vec3 lab = rgb_to_oklab(to_linear(col));
	vec3 cool = rgb_to_oklab(to_linear(shadow_tint));
	vec3 warm = rgb_to_oklab(to_linear(light_tint));
	vec2 axis = warm.yz - cool.yz;
	axis /= max(length(axis), 0.0001);

	lab.x = black_lift + (1.0 - black_lift) * lab.x + aux.z * 0.035 * broken_color;
	float side = dot(lab.yz, axis) * 12.0 // warm things stay warm, cool things stay cool
			+ (lab.x - palette_pivot) * 2.0 // lights lean warm, darks lean cool
			+ 0.7 * smoothstep(0.8, 1.0, lab.x) // the brightest lights turn warm
			- 0.7 * (1.0 - smoothstep(0.0, 0.08, length(lab.yz))) // greys lean cool
			+ aux.y * broken_color * 0.5;
	side *= 1.0 - 2.0 * aux.w;
	side = smoothstep(-0.35, 0.35, side);
	// Darks get less tint so they read as dark rather than as vivid colour,
	// and pale cool dabs stay pale rather than turning electric blue.
	vec2 target = mix(cool.yz * mix(1.0, 0.5, smoothstep(0.55, 0.9, lab.x)), warm.yz, side);
	target *= smoothstep(0.1, 0.55, lab.x);
	lab.yz = mix(lab.yz, target, palette_strength);

	float drift = aux.z * 0.4 * broken_color;
	lab.yz = mat2(vec2(cos(drift), sin(drift)), vec2(-sin(drift), cos(drift))) * lab.yz;
	lab.yz *= saturation;
	vec3 rgb = fit_gamut(oklab_to_rgb(lab), lab.x);

	// Impasto: light the paint relief from the upper left. Multiplying by the
	// sign of the UV derivative keeps "up" correct on every renderer.
	vec2 slope = vec2(dFdx(aux.x) * sign(dFdx(SCREEN_UV.x)), dFdy(aux.x) * sign(dFdy(SCREEN_UV.y)));
	slope *= stroke_size * res.y * 0.14;
	slope /= 1.0 + 2.0 * length(slope);
	vec2 lamp = vec2(-0.6, -0.8);
	float relief = -dot(slope, lamp);
	rgb *= 1.0 + relief * 0.8 * impasto;
	rgb += max(relief - 0.2, 0.0) * 0.6 * impasto;

	// Canvas weave, strongest where the paint is thin.
	vec2 thread = FRAGCOORD.xy * (1080.0 / res.y) * 1.7;
	float weave = sin(thread.x) * (0.6 + 0.4 * sin(thread.y * 0.5 + 1.0)) +
			sin(thread.y) * (0.6 + 0.4 * sin(thread.x * 0.5));
	rgb *= 1.0 + canvas_grain * 0.05 * weave * (1.0 - 0.6 * clamp(aux.x, 0.0, 1.0));

	COLOR = vec4(from_linear(clamp(rgb, vec3(0.0), vec3(1.0))), 1.0);
}
