#version 140

in mediump vec2 var_texcoord0;
in mediump float var_page_index;

out vec4 out_fragColor;

uniform mediump sampler2DArray texture_sampler;

uniform fs_uniforms
{
    mediump vec4 tint;
    mediump vec4 fog;
};

void main()
{
    // textures are premultiplied; fog.w = amount of solid fog colour (GameMaker gpu_set_fog)
    mediump vec4 c = texture(texture_sampler, vec3(var_texcoord0.xy, var_page_index));
    c.rgb = mix(c.rgb, fog.rgb * c.a, fog.w);
    mediump vec4 tint_pm = vec4(tint.xyz * tint.w, tint.w);
    out_fragColor = c * tint_pm;
}
