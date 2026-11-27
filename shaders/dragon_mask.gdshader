shader_type spatial;
render_mode unshaded, fog_disabled, cull_back;
// Verification-only region mask.  Wing membrane comes from the baked G
// channel; dorsal/belly use the same local-normal rule as the colour shader,
// so the sampled regions match what is actually being counter-shaded.
varying vec3 obj_normal;
void vertex() {
    obj_normal = NORMAL;
}
void fragment() {
    vec3 c;
    if (COLOR.g > 0.5) {
        c = vec3(0.0, 0.55, 0.0);       // membrane
    } else if (normalize(obj_normal).y > 0.12) {
        c = vec3(0.55, 0.0, 0.0);       // dorsal
    } else {
        c = vec3(0.0, 0.0, 0.55);       // belly
    }
    ALBEDO = c;
}
