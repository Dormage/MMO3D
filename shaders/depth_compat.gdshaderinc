// Reconstruct the NDC expected by the active renderer's inverse projection.
// Forward+/Mobile use [0, 1] depth; Compatibility uses [-1, 1] NDC depth.
// Applying the Vulkan formula in OpenGL breaks water depth, foam and SSR.
vec3 depth_to_ndc(vec2 uv, float depth) {
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	return vec3(uv, depth) * 2.0 - 1.0;
#else
	return vec3(uv * 2.0 - 1.0, depth);
#endif
}
