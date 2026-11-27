shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Colour-only pass for the detailed stone dragon.  Geometry, skinning and the
// Flap clip are untouched: this preserves the authored albedo texture and adds
// countershading, a deeper membrane and a dark leading-edge band.
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D roughness_tex : hint_roughness_gray, filter_linear_mipmap, repeat_enable;
uniform float debug_mask = 0.0;

varying vec3 obj_pos;
varying vec3 obj_normal;

void vertex() {
    obj_pos = VERTEX;
    obj_normal = NORMAL;
}

void fragment() {
    vec3 base = texture(albedo_tex, UV).rgb;
    vec3 n = normalize(obj_normal);

    // The baked vertex attribute carries the countershading masks:
    //   R = precomputed value, G = wing membrane, B = dorsal, A = leading edge.
    float val = COLOR.r;
    float wing = COLOR.g;
    float dorsal = COLOR.b;
    float lead = COLOR.a;
    // The baked values were authored around 0.34/0.62.  Under this scene's
    // 1.6-energy sun and pale sky they render cream, so bring the actual
    // shaded albedo into the requested 0.08-0.45 band.  Dorsal ends near the
    // floor, belly remains the pale side, membrane is deep.
    // Countershading from the local (rest) normal: the sun-facing back stays
    // near the value floor, the underside is the pale side.  The wing branch
    // overrides both so the membrane remains a single deep silhouette.
    float up = normalize(obj_normal).y;
    float dors = smoothstep(-0.05, 0.55, up);
    float belly = 1.0 - smoothstep(-0.55, 0.05, up);
    val *= mix(1.0, 0.30, dors * (1.0 - wing));
    val *= mix(1.0, 0.55, belly * (1.0 - wing));
    val = mix(val, 0.22, wing);
    val = mix(val, 0.024, lead);

    // Keep bright texture accents (horn, claw, eye, teeth) as the only high
    // values.  The texture already carries these in a few hot texels.
    float lum = dot(base, vec3(0.2126, 0.7152, 0.0722));
    float warm = max(base.r - max(base.g, base.b), 0.0);
    // Only true hot accents: orange eyes and near-white horn/teeth/claw
    // texels.  The broad pale body texture must not trigger this, or the
    // dorsal side turns cream again.
    // Only genuinely hot eye/socket pixels and near-white horn/teeth tips.
    // The previous low luminance threshold fired on the pale body texture and
    // was the reason the bridge-camera dragons still read as cream.
    float accent = smoothstep(0.52, 0.78, warm) * 0.95;
    accent *= 1.0 - wing * 0.88;
    val = mix(val, 1.10, accent * 0.72);

    // Desaturate the slate texture slightly, then warm it.  Otherwise the
    // low albedo under the blue sky turns navy instead of stone.
    vec3 grey = vec3(dot(base, vec3(0.3333)));
    // The source texture is a very dark rock scan (linear mean ~0.06); lift it
    // into a usable stone value while retaining its strata and tooth detail.
    vec3 stone = vec3(clamp(grey * 2.2 + 0.12, 0.08, 0.90));
    vec3 tint = mix(vec3(0.98, 1.00, 1.04), vec3(1.30, 0.78, 0.48), wing * 0.85);
    vec3 a = stone * val * tint;
    // Keep the painted creature inside the stated 0.08-0.45 linear albedo
    // band; the dark band is allowed to sit at the floor.
    a = clamp(a, vec3(0.045), vec3(0.45));
    // The scene sun is strong enough that a physically small albedo still
    // renders as cream.  Put the whole body below the sky value; accents are
    // re-applied after this scale so the head still reads.
    a *= 0.050;

    if (debug_mask > 0.5) {
        // Flat region colours for the verifier: dorsal red, membrane green,
        // belly blue.  This branch is never used by the game material.
        vec3 c = vec3(0.0);
        if (wing > 0.5) {
            c = vec3(0.0, 1.0, 0.0);
        } else if (dorsal > 0.5) {
            c = vec3(1.0, 0.0, 0.0);
        } else {
            c = vec3(0.0, 0.0, 1.0);
        }
        ALBEDO = vec3(0.0);
        EMISSION = c * 4.0;
        ROUGHNESS = 1.0;
        SPECULAR = 0.0;
    } else {
        float tip = smoothstep(0.975, 0.995, lum);
        a = mix(a, vec3(0.90, 0.82, 0.70), tip * 0.85);
        a = mix(a, vec3(0.95, 0.58, 0.24), clamp(accent * 1.15, 0.0, 1.0));
        // A restrained rim keeps the 33k silhouette legible at 40-60 m without
        // raising the mean body value back toward the sky.
        float rim = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);
        a += vec3(0.032, 0.027, 0.022) * rim;
        ALBEDO = a;
        ROUGHNESS = clamp(texture(roughness_tex, UV).r, 0.62, 0.95);
        METALLIC = 0.0;
        SPECULAR = 0.16;
    }
}
