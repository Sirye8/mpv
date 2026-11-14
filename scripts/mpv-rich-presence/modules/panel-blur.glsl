//!PARAM rp_left
//!TYPE float
0.0
//!PARAM rp_top
//!TYPE float
0.0
//!PARAM rp_right
//!TYPE float
0.0
//!PARAM rp_bottom
//!TYPE float
0.0
//!PARAM rp_radius
//!TYPE float
0.0
//!PARAM rp_strength
//!TYPE float
6.0
//!PARAM rp_method
//!TYPE float
0.0

//!HOOK OUTPUT
//!BIND HOOKED
//!DESC Rich Presence panel blur

vec4 hook() {
    vec2 p = HOOKED_pos * HOOKED_size;
    vec2 center = vec2(rp_left + rp_right, rp_top + rp_bottom) * 0.5;
    vec2 extent = vec2(rp_right - rp_left, rp_bottom - rp_top) * 0.5;
    vec2 q = abs(p - center) - extent + rp_radius;
    float edge = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - rp_radius;
    vec4 original = HOOKED_tex(HOOKED_pos);
    if (rp_radius <= 0.0 || edge >= 0.0)
        return original;

    vec2 step = HOOKED_pt * clamp(rp_strength, 2.0, 32.0);
    vec4 effect;
    if (rp_method >= 1.5) {
        vec2 offset = step * 0.65;
        effect = (HOOKED_tex(HOOKED_pos + offset) + HOOKED_tex(HOOKED_pos - offset)
                + HOOKED_tex(HOOKED_pos + vec2(offset.x, -offset.y))
                + HOOKED_tex(HOOKED_pos + vec2(-offset.x, offset.y))) * 0.25;
    } else if (rp_method >= 0.5) {
        effect = vec4(0.0);
        for (int y = -2; y <= 2; ++y) {
            for (int x = -2; x <= 2; ++x) {
                float weight = (3.0 - abs(float(x))) * (3.0 - abs(float(y)));
                effect += weight * HOOKED_tex(HOOKED_pos + vec2(x, y) * step * 0.5);
            }
        }
        effect /= 81.0;
    } else {
        vec4 blur = original * 4.0;
        blur += HOOKED_tex(HOOKED_pos + vec2(step.x, 0.0)) * 2.0;
        blur += HOOKED_tex(HOOKED_pos - vec2(step.x, 0.0)) * 2.0;
        blur += HOOKED_tex(HOOKED_pos + vec2(0.0, step.y)) * 2.0;
        blur += HOOKED_tex(HOOKED_pos - vec2(0.0, step.y)) * 2.0;
        blur += HOOKED_tex(HOOKED_pos + step);
        blur += HOOKED_tex(HOOKED_pos - step);
        blur += HOOKED_tex(HOOKED_pos + vec2(step.x, -step.y));
        blur += HOOKED_tex(HOOKED_pos + vec2(-step.x, step.y));
        effect = blur / 16.0;
    }
    return mix(original, effect, smoothstep(0.0, 2.0, -edge));
}
